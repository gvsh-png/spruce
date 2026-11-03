import AppKit
import Observation
import UserNotifications

/// A proposed rename, ready to apply or to edit first (capture panel, bulk rename).
struct Proposal: Identifiable {
    let id = UUID()
    var url: URL
    var stem: String
    var dir: URL
    var provider: String
    var kind: String?
    /// Every readable line, for "Copy Text".
    var text: String
    var include = true
    /// Live captures only: used to spot bursts of near-duplicates.
    var live = false
    var app: String?
    var date = Date()
    var words: Set<String> = []
    /// Keep forever: goes to the Kept folder and never expires.
    var keep = false
    /// What the QR codes in the screenshot say, if any.
    var codes: [String] = []
    /// OCR lines with positions, saved next to the file so the Screenshot Manager can search inside it.
    var lines: [OCRLine] = []
}

/// The screenshot shown in the capture panel right now.
struct Capture {
    var url: URL
    var thumbnail: NSImage?
    var proposal: Proposal?
    /// Earlier near-duplicates this capture replaced, with where they went in the Trash.
    var replaced: [(trashed: URL, entry: HistoryEntry)] = []
    /// The name so far, while the model is still writing it.
    var partial: String?
    /// Set once the name has been applied early (when the thumbnail is dragged out).
    var appliedURL: URL?
    /// Where the file went after Delete; non-nil while the island shows "Moved to Trash · Undo".
    var trashedURL: URL?
    /// What the user typed in the name field, so a newer screenshot arriving mid-edit doesn't lose it.
    var edited: String?
}

/// Runs the pipeline and holds everything the UI shows.
///
///   FolderWatcher (new file) → private-app check → OCR (Vision, on-device) → TextRules.rankedText
///   → Namer (AI, with retries) → Proposal → [capture panel: edit, move, delete] → apply:
///   FileOps.move + Finder tag + History
///
/// `propose` never touches the file; `apply` is the only step that renames it. That split lets the
/// capture panel and bulk rename show names before anything changes on disk.
@MainActor @Observable
final class AppState {
    var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            if prefs.watching != oldValue.watching || prefs.watchFolders != oldValue.watchFolders
                || prefs.prefixList != oldValue.prefixList { restartWatcher() }
        }
    }
    var history: [HistoryEntry] = History.load()
    var queued = 0
    var isProcessing = false
    var lastError: String?
    var unreadableFolders: [String] = []

    /// Non-nil while the capture panel is on screen.
    var capture: Capture?
    /// Bumped on each new screenshot and each rename; the menu bar icon animates on change.
    var captureCount = 0
    var renameCount = 0
    /// True for a moment after a rename: the menu bar icon shows a check.
    var justRenamed = false

    /// Bulk rename preview.
    var bulk: [Proposal] = []
    var bulkDone = 0
    var bulkTotal = 0
    var bulkRunning = false
    private var bulkTask: Task<Void, Never>?

    enum Status { case paused, watching, processing }
    var status: Status { isProcessing || bulkRunning ? .processing : (prefs.watching ? .watching : .paused) }

    private struct Job { var url: URL; var app: String?; var date: Date }
    private var queue: [Job] = []
    private let watcher = FolderWatcher()
    /// The last live capture that was applied, for burst detection.
    private var lastLive: (id: UUID, words: Set<String>, app: String?, date: Date)?
    /// The screenshot auto-copied on arrival and the clipboard's change count right after, so the
    /// clipboard can be pointed at the renamed file if nothing else was copied meanwhile.
    private var autoCopied: (url: URL, change: Int)?
    private var expiryTimer: Timer?

    init() {
        prefs = Preferences.load()
        watcher.onScreenshot = { [weak self] url in self?.screenshotArrived(url) }
        restartWatcher()
        Notifier.setUp(self)
        Namer.prewarm()
        // ⌥⇧⌘4 starts a scroll capture; pressed again while capturing, it finishes.
        Hotkey.register { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ScrollCapture.shared.isRunning { ScrollCapture.shared.stop(save: true) } else { ScrollCapture.shared.start(self) }
            }
        }
        expireOld()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireOld() }
        }
    }

    func restartWatcher() {
        watcher.stop()
        unreadableFolders = []
        guard prefs.watching else { return }
        watcher.namePrefixes = prefs.prefixList
        let folders = prefs.watchFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        unreadableFolders = watcher.start(folders: folders).map(\.path)
    }

    // MARK: Live screenshots

    private func screenshotArrived(_ url: URL) {
        // A file we already have on the island or in the queue showing up again (e.g. put back by
        // Undo after Delete) is not a new screenshot.
        if capture?.url == url || queue.contains(where: { $0.url == url }) { return }
        let front = NSWorkspace.shared.frontmostApplication
        if prefs.copyToClipboard, Self.copyToClipboard(url) {
            autoCopied = (url, NSPasteboard.general.changeCount)
        }

        // Private apps: keep the original name and never send anything to a model.
        if let id = front?.bundleIdentifier, prefs.privateApps.contains(id) { return }

        captureCount += 1
        if prefs.showPanel {
            finishCapture() // a newer screenshot replaces the one on screen; that one is applied as is
            capture = Capture(url: url, thumbnail: OCR.thumbnail(of: url, maxPixel: 240).flatMap(NSImage.init(data:)))
            CapturePanel.shared.show(self)
        }
        // The app in front when the screenshot appeared; used for the fallback name.
        queue.append(Job(url: url, app: front?.localizedName, date: Date()))
        queued = queue.count
        if !isProcessing {
            isProcessing = true // set now, so files arriving in the same pass don't start a second drain
            Task { await drain() }
        }
    }

    private func drain() async {
        defer { isProcessing = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            queued = queue.count
            let url = job.url
            let onPartial: (String?) -> Void = { [weak self] text in
                Task { @MainActor in
                    guard let self, self.capture?.url == url, self.capture?.proposal == nil else { return }
                    self.capture?.partial = text
                }
            }
            guard var proposal = await propose(job.url, app: job.app, date: job.date, onPartial: onPartial) else {
                // Unreadable or gone: never leave the island waiting on "Naming…".
                if capture?.url == job.url { dismissCapture() }
                continue
            }
            proposal.live = true
            proposal.app = job.app
            proposal.date = job.date
            // Only while the island shows this capture: it is where the Undo for the collapse lives.
            if prefs.collapseBursts, capture?.url == job.url, let removed = collapseBurst(before: proposal) {
                capture?.replaced.append(removed)
            }
            if capture?.url == job.url {
                capture?.proposal = proposal // the panel applies it (timeout, Return, Move or close)
            } else {
                apply(proposal)
            }
        }
    }

    /// Applies the panel's proposal, with the user's edited name if they typed one.
    func finishCapture(stem edited: String? = nil, dir: URL? = nil, keep: Bool = false) {
        guard let current = capture else { return }
        capture = nil
        CapturePanel.shared.hide()
        guard current.trashedURL == nil else { return } // deleted: nothing to apply
        guard var proposal = current.proposal else { return } // still naming: `drain` applies it when ready
        if let done = current.appliedURL {
            // Already applied when copied or dragged out: start from there, so a later Move, Keep or
            // new name still takes effect. Unchanged, this is a no-op.
            proposal.url = done
            proposal.live = false
        }
        if let edited = edited ?? current.edited, !edited.trimmingCharacters(in: .whitespaces).isEmpty { proposal.stem = edited }
        if let dir { proposal.dir = dir }
        if keep {
            proposal.keep = true
            proposal.dir = current.url.deletingLastPathComponent().appendingPathComponent(FileOps.keptFolder, isDirectory: true)
        }
        apply(proposal)
    }

    /// Applies the name now but keeps the island open; used when the thumbnail is dragged out or
    /// copied, so the file lands in the other app under its new name. Returns where the file is.
    func applyCaptureNow(stem edited: String?) -> URL? {
        guard let current = capture else { return nil }
        if let done = current.appliedURL { return done }
        guard var proposal = current.proposal else { return current.url }
        if let edited, !edited.trimmingCharacters(in: .whitespaces).isEmpty { proposal.stem = edited }
        guard let dest = apply(proposal) else { return current.url }
        capture?.appliedURL = dest
        return dest
    }

    /// Moves the panel's screenshot to the Trash instead of renaming it.
    /// The island stays open for a moment afterwards with Undo.
    func trashCapture() {
        guard let current = capture, current.trashedURL == nil else { return }
        let file = current.appliedURL ?? current.url
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
            capture?.trashedURL = trashed as URL?
            Self.trashSound?.play()
        } catch {
            lastError = "Couldn't move “\(file.lastPathComponent)” to the Trash: \(error.localizedDescription)"
            dismissCapture()
        }
    }

    /// Undo for Delete: puts the file back and returns the island to normal.
    func undoTrash() {
        guard let current = capture, let trashed = current.trashedURL else { return }
        do {
            try FileManager.default.moveItem(at: trashed, to: current.appliedURL ?? current.url)
            capture?.trashedURL = nil
        } catch {
            lastError = "Couldn't put “\(current.url.lastPathComponent)” back. It's still in the Trash."
        }
    }

    /// Closes the island without renaming anything.
    func dismissCapture() {
        capture = nil
        CapturePanel.shared.hide()
    }

    /// Finder's own "move to Trash" sound.
    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true)

    // MARK: Pipeline

    /// OCR, AI and naming rules. Reads the file but never changes it.
    /// `onPartial` gets the streamed name, cased with the same OCR text as the final one.
    private func propose(_ url: URL, app: String?, date: Date, onPartial: ((String?) -> Void)? = nil) async -> Proposal? {
        let prefs = self.prefs
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // 1. OCR on-device, off the main thread.
        let lines: [OCRLine], codes: [String]
        do { (lines, codes) = try await Task.detached(priority: .utility) { try OCR.read(url) }.value }
        catch {
            lastError = "Skipped “\(url.lastPathComponent)”: it isn't a readable image."
            return nil
        }

        // 2. Keep the most telling text; add a small image only when there's almost none.
        let text = TextRules.rankedText(lines)
        let image = text.count < TextRules.thinTextThreshold
            ? await Task.detached(priority: .utility) { OCR.thumbnail(of: url) }.value
            : nil

        // 3. Ask the model. Retry connection problems twice (after 2 s, then 6 s), then fall back.
        let partial: (([String]) -> Void)? = onPartial.map { report in
            { words in report(TextRules.stem(words: words, style: prefs.style, date: nil, casingSource: text)) }
        }
        let namer = Namer(prefs: prefs, apiKey: Keychain.get())
        var suggestion: Suggestion?
        var provider = "fallback"
        for attempt in 0..<3 {
            do {
                let (s, p) = try await namer.suggest(NamingInput(text: text, image: image), onPartial: partial)
                suggestion = TextRules.cleaned(s)
                provider = p
                lastError = nil
                break
            } catch let error as NamingError where error.isRetryable && attempt < 2 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 2_000_000_000 : 6_000_000_000)
            } catch NamingError.noText {
                break // expected for text-free screenshots; the fallback name is used
            } catch {
                lastError = error.localizedDescription
                break
            }
        }

        // 4. Safe name, folder and tag.
        let stem = suggestion.flatMap { TextRules.stem(words: $0.words, style: prefs.style, date: prefs.includeDate ? date : nil,
                                                       casingSource: text) }
            ?? TextRules.fallbackStem(app: app, date: date, style: prefs.style)
        let here = url.deletingLastPathComponent()
        var dir = here
        if prefs.sortingEnabled, let folder = TextRules.matchFolder(suggestion?.folder, allowed: prefs.folders),
           !folder.split(separator: "/").contains("..") { // stay inside the watched folder
            dir = here.appendingPathComponent(folder, isDirectory: true)
        }
        let fullText = TextRules.fullText(lines)
        return Proposal(url: url, stem: stem, dir: dir, provider: provider,
                        kind: TextRules.matchKind(suggestion?.kind), text: fullText, words: TextRules.wordSet(fullText), codes: codes, lines: lines)
    }

    /// The only step that changes the file: mark, move, tag, log.
    /// Returns where the file ended up, or nil if it couldn't be renamed.
    @discardableResult
    func apply(_ p: Proposal, batch: UUID? = nil) -> URL? {
        guard FileManager.default.fileExists(atPath: p.url.path) else { return nil } // deleted or moved meanwhile
        do {
            // Names may have been edited by hand (panel, bulk list): make them safe, but keep the
            // user's casing and the date prefix as they are.
            let stem = TextRules.normalizeEdited(p.stem, style: prefs.style) ?? p.stem
            // Marked only after the move worked; the watcher runs on this same thread, so it can't
            // see the new name before the mark is on it.
            let dest = try FileOps.move(p.url, toDir: p.dir, stem: stem, style: prefs.style)
            XAttr.markDone(dest)
            // Private-app screenshots never get here: they are never read, so there is no text to save.
            XAttr.setText(dest, lines: TextRules.storedLines(p.lines))
            if prefs.tagsEnabled, let kind = p.kind { FileOps.addTag(kind, to: dest) }
            if p.keep { XAttr.markKept(dest) }
            guard dest != p.url else { return dest } // already had this name: nothing to log or undo
            let entry = HistoryEntry(batch: batch, date: Date(), from: p.url.path, to: dest.path, provider: p.provider, prompt: Prompt.version)
            history.insert(entry, at: 0)
            History.append(entry, all: history)
            if history.count > History.cap + 100 { history.removeLast(history.count - History.cap) } // the file was just trimmed too
            if batch == nil, prefs.notify, !prefs.showPanel { Notifier.renamed(entry) }
            if p.live {
                lastLive = (entry.id, p.words, p.app, p.date)
                // A light tick on the trackpad, and a check on the menu bar icon for a moment.
                if prefs.haptic { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
                renameCount += 1
                justRenamed = true
                // Auto-copied on arrival under the old name: point the clipboard at the renamed file,
                // unless something else has been copied since.
                if let copied = autoCopied, copied.url == p.url {
                    autoCopied = nil
                    if NSPasteboard.general.changeCount == copied.change { Self.copyToClipboard(dest) }
                }
                Task { try? await Task.sleep(nanoseconds: 1_600_000_000); justRenamed = false }
            }
            return dest
        } catch {
            lastError = "Couldn't rename “\(p.url.lastPathComponent)”: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Clutter

    /// If the previous live capture shows the same thing (under a minute ago, same app, same text),
    /// moves it to the Trash and returns where it went, so the island can offer Undo.
    private func collapseBurst(before p: Proposal) -> (trashed: URL, entry: HistoryEntry)? {
        guard let last = lastLive, p.date.timeIntervalSince(last.date) <= 60, last.app == p.app,
              TextRules.isBurst(last.words, p.words),
              let entry = history.first(where: { $0.id == last.id }) else { return nil }
        let url = URL(fileURLWithPath: entry.to)
        // Moved, renamed or kept by hand since: the user cares about it, leave it.
        guard FileManager.default.fileExists(atPath: url.path), !XAttr.isKept(url) else { return nil }
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil,
              let trashedURL = trashed as URL? else { return nil }
        history.removeAll { $0.id == entry.id }
        History.rewrite(history)
        lastLive = nil
        return (trashedURL, entry)
    }

    /// Undo for collapsed bursts: brings the replaced screenshots back from the Trash.
    func restoreReplaced() {
        guard let replaced = capture?.replaced, !replaced.isEmpty else { return }
        for (trashed, entry) in replaced where !FileManager.default.fileExists(atPath: entry.to) {
            do {
                try FileManager.default.moveItem(at: trashed, to: URL(fileURLWithPath: entry.to))
                history.append(entry)
            } catch {
                lastError = "Couldn't restore “\((entry.to as NSString).lastPathComponent)”. It's still in the Trash."
            }
        }
        history.sort { $0.date > $1.date }
        History.rewrite(history)
        capture?.replaced = []
    }

    /// Would this rename expire? Only live captures, still where and as the app left them.
    /// Anything sorted into a folder, kept, renamed or moved by hand stays.
    func willExpire(_ entry: HistoryEntry) -> Bool {
        guard prefs.expireEnabled, entry.batch == nil,
              (entry.to as NSString).deletingLastPathComponent == (entry.from as NSString).deletingLastPathComponent
        else { return false }
        let url = URL(fileURLWithPath: entry.to)
        return FileManager.default.fileExists(atPath: url.path) && !XAttr.isKept(url) && XAttr.doneDate(url) != nil
    }

    /// Moves expired screenshots to the Trash (macOS keeps them there another 30 days). Runs hourly.
    func expireOld() {
        guard prefs.expireEnabled else { return }
        let cutoff = Date().addingTimeInterval(-Double(prefs.expireDays) * 86_400)
        var expired: [UUID] = []
        for entry in history where willExpire(entry) {
            let url = URL(fileURLWithPath: entry.to)
            guard let done = XAttr.doneDate(url), done < cutoff,
                  (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil else { continue }
            expired.append(entry.id)
        }
        guard !expired.isEmpty else { return }
        history.removeAll { expired.contains($0.id) }
        History.rewrite(history)
        if prefs.notify { Notifier.expired(count: expired.count, days: prefs.expireDays) }
    }

    /// Keeps an already renamed screenshot: moves it to the Kept folder so it never expires.
    func keep(_ entry: HistoryEntry) {
        do {
            let dest = try FileOps.keep(URL(fileURLWithPath: entry.to), style: prefs.style)
            if let i = history.firstIndex(where: { $0.id == entry.id }) { history[i].to = dest.path }
            History.rewrite(history)
        } catch {
            lastError = "Couldn't keep “\((entry.to as NSString).lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    // MARK: Bulk rename

    /// Finds screenshots in `folder` that still have their system name and proposes a name for each.
    func scanForBulk(_ folder: URL) {
        bulkTask?.cancel()
        bulk = []
        bulkDone = 0
        bulkTotal = 0
        bulkRunning = true
        let prefixes = prefs.prefixList
        bulkTask = Task {
            // Listing a big folder and reading attributes takes a while: keep it off the main thread.
            let files = await Task.detached(priority: .userInitiated) {
                ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? [])
                    .filter {
                        FolderWatcher.extensions.contains($0.pathExtension.lowercased())
                            && TextRules.looksDefaultName($0.lastPathComponent)
                            && !XAttr.isDone($0)
                            && (XAttr.isScreenCapture($0) || prefixes.contains(where: $0.lastPathComponent.hasPrefix))
                    }
                    .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) }
                    .sorted { $0.1 > $1.1 } // newest first
            }.value
            guard !Task.isCancelled else { return }
            bulkTotal = files.count
            for (url, created) in files {
                if Task.isCancelled { return }
                let p = await propose(url, app: nil, date: created)
                if Task.isCancelled { return } // stopped or rescanned meanwhile: don't add to the new list
                if let p { bulk.append(p) }
                bulkDone += 1
            }
            bulkRunning = false
        }
    }

    func stopBulk() {
        bulkTask?.cancel()
        bulkRunning = false
    }

    /// Renames every ticked file as one batch: "Undo Last" reverts all of them.
    func applyBulk() {
        stopBulk()
        let batch = UUID()
        let picked = bulk.filter(\.include)
        let done = picked.filter { apply($0, batch: batch) != nil }.count
        bulk = []
        if done > 0, prefs.notify { Notifier.batch(count: done) }
    }

    // MARK: Actions

    /// Copies the image and the file together: image editors paste the pixels, while Finder, Mail
    /// and chat apps paste the file under its name. Returns false if the file couldn't be read.
    @discardableResult
    static func copyToClipboard(_ url: URL) -> Bool {
        let item = NSPasteboardItem()
        // PNG bytes as they are: no decode, no 50 MB TIFF for a Retina screenshot.
        if url.pathExtension.lowercased() == "png", let png = try? Data(contentsOf: url) {
            item.setData(png, forType: .png)
        } else {
            guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation else { return false }
            item.setData(tiff, forType: .tiff)
        }
        item.setString(url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The most recent rename, or the whole batch it belongs to.
    var lastGroup: [HistoryEntry] {
        guard let first = history.first else { return [] }
        guard let batch = first.batch else { return [first] }
        return history.filter { $0.batch == batch }
    }

    func undoLast() { undo(lastGroup) }

    func undo(_ entries: [HistoryEntry]) {
        var failures: [String] = []
        for entry in entries {
            do {
                try FileOps.undo(entry)
                history.removeAll { $0.id == entry.id }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        History.rewrite(history)
        lastError = failures.isEmpty ? nil
            : failures.count == 1 ? failures[0] : "\(failures.count) files couldn't be undone. \(failures[0])"
    }
}

/// macOS notifications with an Undo button. Used when the capture panel is turned off, and for bulk renames.
enum Notifier {
    static let undoAction = "undo"
    static let category = "renamed"
    private static let delegate = Delegate()

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        weak var state: AppState?

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard response.actionIdentifier == Notifier.undoAction else { return }
            let info = response.notification.request.content.userInfo
            await MainActor.run {
                guard let state else { return }
                if let id = (info["id"] as? String).flatMap(UUID.init), let entry = state.history.first(where: { $0.id == id }) {
                    state.undo([entry])
                } else if let batch = (info["batch"] as? String).flatMap(UUID.init) {
                    state.undo(state.history.filter { $0.batch == batch })
                }
            }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner]
        }
    }

    @MainActor static func setUp(_ state: AppState) {
        delegate.state = state
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [UNNotificationAction(identifier: undoAction, title: "Undo")], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func renamed(_ entry: HistoryEntry) {
        post(body: "Renamed to “\((entry.to as NSString).lastPathComponent)”", info: ["id": entry.id.uuidString])
    }

    static func expired(count: Int, days: Int) {
        post(body: "Moved \(count) screenshot\(count == 1 ? "" : "s") older than \(days) days to the Trash", info: [:])
    }

    @MainActor static func batch(count: Int) {
        guard let batch = delegate.state?.history.first?.batch else { return }
        post(body: "Renamed \(count) screenshots", info: ["batch": batch.uuidString])
    }

    private static func post(body: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = "Spruce"
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
