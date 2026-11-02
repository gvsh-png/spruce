import Foundation
import Security

/// User settings, stored as one JSON blob in UserDefaults.
struct Preferences: Codable, Equatable {
    var watching = true
    var watchFolders: [String] = [Preferences.systemScreenshotFolder]
    var style: NamingStyle = .kebab
    var includeDate = false
    var notify = true
    /// Put each new screenshot on the clipboard the moment it is saved, before renaming.
    var copyToClipboard = true
    /// Show the capture panel (name, Copy, Copy Text, Move, Delete) after each screenshot.
    var showPanel = true
    /// Seconds the island stays after the name appears (hovering or typing pauses it).
    var islandSeconds = 5.0
    /// Larger preview when resting on the thumbnail, and how long to rest first.
    var peekEnabled = true
    var peekDelay = 0.35
    /// Light trackpad tick when a name is applied.
    var haptic = true
    /// Bouncy spring when the island opens; off gives a calm ease.
    var bouncy = true
    /// Move screenshots to the Trash after `expireDays` unless kept, renamed or moved by hand.
    var expireEnabled = true
    var expireDays = 14
    /// When the same thing is captured twice within a minute, keep only the newest.
    var collapseBursts = true
    /// Add a Finder tag such as "Receipt" or "Code".
    var tagsEnabled = true
    /// Bundle IDs of apps whose screenshots keep their name and never reach any AI.
    var privateApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                       "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.MobileSMS"]

    /// Also accept files from other screenshot tools by filename prefix.
    var matchByName = false
    var namePrefixes = "Screenshot, CleanShot"

    var provider: ProviderMode = .auto
    var ollamaURL = "http://localhost:11434/v1"
    var ollamaModel = "gemma3:4b"
    var cloudURL = "https://api.anthropic.com/v1"
    var cloudModel = "claude-haiku-5-5"
    var allowCloudImages = false

    var sortingEnabled = false
    var folders = ["Receipts", "Work", "Design", "Personal"]

    var prefixList: [String] {
        matchByName ? namePrefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
    }

    /// Where macOS saves screenshots (Screenshot app → Options → Save to), else Desktop.
    static var systemScreenshotFolder: String {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return custom.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/Desktop"
    }

    private static let key = "preferences"

    /// Stored values win; keys added in newer versions fall back to their defaults.
    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(stored) { _, saved in saved }),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: merged)
        else { return Preferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The cloud API key lives in the login Keychain, never in UserDefaults.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.screenshotrenamer.app.cloud-api-key",
    ]

    static func get() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String) {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// One rename, as stored in the history log.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Set for bulk renames, so one Undo reverts the whole batch.
    var batch: UUID? = nil
    var date: Date
    var from: String
    var to: String
    var provider: String
    var prompt: String
}

/// Step 4 of the pipeline: move the file to its new name and keep an undo log.
///
/// The log is an append-only JSON Lines file in Application Support, newest last, capped at 1,000 entries.
enum History {
    static let cap = 1000
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenshotRenamer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }()

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Newest first.
    static func load() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }.reversed()
    }

    /// Appends one entry. `all` is the in-memory list (newest first), used to rewrite when over the cap.
    static func append(_ entry: HistoryEntry, all: [HistoryEntry]) {
        if all.count > cap + 100 { return rewrite(all) }
        guard let line = try? encoder.encode(entry) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: url)
        }
    }

    static func rewrite(_ all: [HistoryEntry]) {
        let lines = all.prefix(cap).reversed().compactMap { try? encoder.encode($0) }
        try? Data(lines.joined(separator: Data("\n".utf8)) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

enum FileOps {
    enum UndoError: LocalizedError {
        case missing(String), occupied(String)
        var errorDescription: String? {
            switch self {
            case .missing(let name): "Can't undo: “\(name)” was moved or deleted."
            case .occupied(let name): "Can't undo: a file named “\(name)” already exists."
            }
        }
    }

    /// Moves `file` to `dir/stem.ext`, never overwriting: a taken name gets "-2", "-3"….
    static func move(_ file: URL, toDir dir: URL, stem: String, style: NamingStyle) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = TextRules.uniqueURL(in: dir, stem: stem, ext: file.pathExtension.lowercased(), separator: style.separator) {
            $0.standardizedFileURL != file.standardizedFileURL && fm.fileExists(atPath: $0.path)
        }
        if dest.standardizedFileURL == file.standardizedFileURL { return file }
        try fm.moveItem(at: file, to: dest) // fails rather than overwrites if the name was taken meanwhile
        return dest
    }

    /// Adds a Finder tag, keeping any tags the file already has.
    static func addTag(_ tag: String, to url: URL) {
        let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        guard !existing.contains(tag) else { return }
        try? (url as NSURL).setResourceValue(existing + [tag], forKey: .tagNamesKey)
    }

    /// Moves a renamed file into a "Kept" folder next to it and marks it, so it never expires.
    static func keep(_ url: URL, style: NamingStyle) throws -> URL {
        let dir = url.deletingLastPathComponent().appendingPathComponent(keptFolder, isDirectory: true)
        let dest = try move(url, toDir: dir, stem: url.deletingPathExtension().lastPathComponent, style: style)
        XAttr.markKept(dest)
        return dest
    }

    static let keptFolder = "Kept"

    /// Puts a file back where it was, only if it is still at its new path and the old name is free.
    static func undo(_ entry: HistoryEntry) throws {
        let fm = FileManager.default
        let to = URL(fileURLWithPath: entry.to), from = URL(fileURLWithPath: entry.from)
        guard fm.fileExists(atPath: to.path) else { throw UndoError.missing(to.lastPathComponent) }
        guard !fm.fileExists(atPath: from.path) else { throw UndoError.occupied(from.lastPathComponent) }
        try fm.moveItem(at: to, to: from)
    }
}
