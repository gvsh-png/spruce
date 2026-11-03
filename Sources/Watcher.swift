import Foundation

/// Step 1 of the pipeline: watch folders (top level only) and report new screenshots
/// once macOS has finished writing them.
///
/// macOS first writes a hidden `.Screenshot…` temp file, then renames it into place.
/// So we skip dotfiles and wait until the file size stops changing (checked every 0.25 s) before reporting.
final class FolderWatcher {
    /// Called on the main queue with each new screenshot.
    var onScreenshot: (URL) -> Void = { _ in }
    /// Filename prefixes accepted even without the macOS screenshot flag
    /// (CleanShot, Shottr and similar tools don't set it). Empty = flag only.
    var namePrefixes: [String] = []

    static let extensions: Set = ["png", "jpg", "jpeg", "heic"]

    private var sources: [DispatchSourceFileSystemObject] = []
    private var known: [URL: Set<String>] = [:]

    /// Starts watching. Files already in a folder are left alone; only new arrivals are reported.
    /// Returns the folders that could not be opened (missing, or folder access denied).
    @discardableResult
    func start(folders: [URL]) -> [URL] {
        stop()
        var failed: [URL] = []
        for dir in folders {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { failed.append(dir); continue }
            known[dir] = Set(list(dir))
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.scan(dir) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        return failed
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        known = [:]
    }

    private func list(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// A directory "write" event only says something changed, so diff the listing.
    private func scan(_ dir: URL) {
        let now = Set(list(dir))
        let added = now.subtracting(known[dir] ?? [])
        known[dir] = now
        for name in added where !name.hasPrefix(".")
            && Self.extensions.contains((name as NSString).pathExtension.lowercased()) {
            let url = dir.appendingPathComponent(name)
            // macOS writes its screenshots to a hidden temp file and renames them into place with the
            // screenshot flag already set, so they are complete on arrival: report them at once.
            if XAttr.isScreenCapture(url) { accept(url) } else { waitUntilSettled(url, lastSize: -1, tries: 0) }
        }
    }

    private func waitUntilSettled(_ url: URL, lastSize: Int, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            else { return } // gone: renamed or deleted meanwhile
            if size > 0 && size == lastSize {
                self.accept(url)
            } else if tries < 40 {
                self.waitUntilSettled(url, lastSize: size, tries: tries + 1)
            }
        }
    }

    private func accept(_ url: URL) {
        guard !XAttr.isDone(url) else { return } // our own rename showing up again
        let name = url.lastPathComponent
        guard XAttr.isScreenCapture(url) || namePrefixes.contains(where: { name.hasPrefix($0) }) else { return }
        onScreenshot(url)
    }
}

/// Extended attributes: the flag macOS stamps on screenshots, and our own "already handled" mark.
/// Our mark travels with the file through moves, so a renamed file is never processed twice.
enum XAttr {
    static let doneKey = "com.screenshotrenamer.done"
    static let screenCaptureKey = "com.apple.metadata:kMDItemIsScreenCapture"

    /// True for files macOS's own screenshot tool created, in any system language.
    static func isScreenCapture(_ url: URL) -> Bool {
        guard let data = get(url, screenCaptureKey),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    static let keptKey = "com.screenshotrenamer.kept"

    /// Stamps a file the way macOS stamps its own screenshots (used for scroll captures).
    static func markScreenCapture(_ url: URL) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = data.withUnsafeBytes { setxattr(path, screenCaptureKey, $0.baseAddress, data.count, 0, 0) }
        }
    }

    static func isDone(_ url: URL) -> Bool { get(url, doneKey) != nil }

    /// The "done" mark holds the time the app handled the file. Files marked by older versions
    /// hold "1" and have no date, so they never expire.
    static func markDone(_ url: URL) { set(url, doneKey, ISO8601DateFormatter().string(from: Date())) }

    static func doneDate(_ url: URL) -> Date? {
        get(url, doneKey).flatMap { ISO8601DateFormatter().date(from: String(decoding: $0, as: UTF8.self)) }
    }

    /// Kept files never expire.
    static func isKept(_ url: URL) -> Bool { get(url, keptKey) != nil }
    static func markKept(_ url: URL) { set(url, keptKey, "1") }

    private static func set(_ url: URL, _ name: String, _ value: String) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let bytes = Array(value.utf8)
            _ = setxattr(path, name, bytes, bytes.count, 0, 0)
        }
    }

    static func get(_ url: URL, _ name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
    }
}
