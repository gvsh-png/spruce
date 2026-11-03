import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// Scroll capture: drag over a scrollable area, scroll through it as usual, press Done. Spruce takes
/// a frame every ~80 ms, keeps only the rows that scrolled into view, and saves one tall screenshot
/// into the screenshot folder, where it is named like any other.
@MainActor
final class ScrollCapture {
    static let shared = ScrollCapture()

    /// What the controls show while capturing.
    @Observable final class Status {
        var pixels = 0
        var lost = false
        var full = false
    }

    private var overlay: Overlay?
    private var controls: NSPanel?
    private var loop: Task<Void, Never>?
    private var stitcher: Stitcher?
    private var previousApp: NSRunningApplication?
    private weak var state: AppState?
    private let status = Status()

    var isRunning: Bool { overlay != nil }

    func start(_ state: AppState) {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else { return askForPermission() }
        self.state = state
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let overlay = Overlay(screen: screen)
        overlay.onSelect = { [weak self] rect in self?.begin(rect, on: screen) }
        overlay.onCancel = { [weak self] in self?.stop(save: false) }
        self.overlay = overlay
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)
    }

    /// The area is chosen: hand the keyboard and scrolling back to the app underneath and start taking frames.
    private func begin(_ rect: NSRect, on screen: NSScreen) {
        overlay?.capture(rect)
        previousApp?.activate()
        status.pixels = 0
        status.lost = false
        status.full = false
        showControls(below: rect, on: screen)

        let stitcher = Stitcher(scrollbarPoints: 16 * screen.backingScaleFactor)
        self.stitcher = stitcher
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        // ScreenCaptureKit measures from the display's top-left corner, in points.
        let source = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor

        loop = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                // Leave Spruce's own overlay and controls out of the frames.
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = source
                config.width = Int(source.width * scale)
                config.height = Int(source.height * scale)
                config.showsCursor = false
                while !Task.isCancelled {
                    let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let result = await stitcher.add(frame)
                    guard let self, !Task.isCancelled else { return }
                    status.pixels = result.height
                    status.lost = result.lost
                    if result.full { status.full = true; return stop(save: true) }
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
            } catch is CancellationError {
            } catch {
                self?.state?.lastError = "Scroll capture stopped: \(error.localizedDescription)"
                self?.stop(save: false)
            }
        }
    }

    func stop(save: Bool) {
        loop?.cancel()
        loop = nil
        overlay?.orderOut(nil)
        overlay = nil
        controls?.orderOut(nil)
        controls = nil
        guard save, let stitcher, let state else { self.stitcher = nil; return }
        self.stitcher = nil
        let folder = URL(fileURLWithPath: state.prefs.watchFolders.first ?? Preferences.systemScreenshotFolder, isDirectory: true)
        Task {
            // Encoding a tall PNG takes a moment; do it off the main thread.
            let saved = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error>? in
                guard let image = await stitcher.image() else { return nil }
                return Result { try Self.write(image, into: folder) }
            }.value
            if case .failure(let error) = saved {
                state.lastError = "Couldn't save the scroll capture: \(error.localizedDescription)"
            }
        }
    }

    /// Saves under the system's own screenshot name and flag, so the watcher names it like any other.
    nonisolated private static func write(_ image: CGImage, into folder: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'Screenshot' yyyy-MM-dd 'at' HH.mm.ss"
        let url = TextRules.uniqueURL(in: folder, stem: formatter.string(from: Date()), ext: "png", separator: "-") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        XAttr.markScreenCapture(url)
        return url
    }

    private func showControls(below rect: NSRect, on screen: NSScreen) {
        let size = NSSize(width: 340, height: 44)
        // Under the area if there's room, else above it, else inside its bottom edge.
        var y = rect.minY - size.height - 12
        if y < screen.visibleFrame.minY { y = rect.maxY + 12 }
        if y + size.height > screen.visibleFrame.maxY { y = rect.minY + 12 }
        let panel = NSPanel(contentRect: NSRect(x: rect.midX - size.width / 2, y: y, width: size.width, height: size.height),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollControls(status: status,
                                                                   done: { [weak self] in self?.stop(save: true) },
                                                                   cancel: { [weak self] in self?.stop(save: false) }))
        panel.orderFrontRegardless()
        controls = panel
    }

    private func askForPermission() {
        let alert = NSAlert()
        alert.messageText = "Turn on Screen Recording for Spruce"
        alert.informativeText = """
            Scroll capture needs to see the area you pick while you scroll.

            Click Open System Settings, switch Spruce on, and choose Quit & Reopen when macOS asks. \
            If Spruce isn't in the list, click + under it and pick Spruce from Applications.

            Spruce only looks at the area you choose, and only while you scroll.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // Asking ScreenCaptureKit for the screen is what adds Spruce to the list on current macOS;
            // CGRequestScreenCaptureAccess alone often doesn't.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Holds the growing image. Runs off the main thread: each frame is decoded, fingerprinted and
/// matched here, and only the newly visible rows are copied.
private actor Stitcher {
    /// About 25,000 px tall at most (≈150 MB for a wide area); the capture finishes there.
    static let maxRows = 25_000

    private let scrollbar: Int
    private var width = 0, bytesPerRow = 0
    private var out: [UInt8] = []
    private var last: Stitch.Rows?

    init(scrollbarPoints: CGFloat) { scrollbar = Int(scrollbarPoints) }

    func add(_ image: CGImage) -> (height: Int, lost: Bool, full: Bool) {
        let w = image.width, h = image.height, bpr = w * 4
        var frame = [UInt8](repeating: 0, count: bpr * h)
        let drawn = frame.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return (out.count / max(bytesPerRow, 1), false, false) }
        let rows = frame.withUnsafeBytes { Stitch.rows($0, width: w, height: h, bytesPerRow: bpr, columns: w - scrollbar) }

        guard let previous = last, width == w else {
            width = w
            bytesPerRow = bpr
            out = frame
            last = rows
            return (h, false, false)
        }
        // No match: scrolled too fast. Keep the last good frame so scrolling back a little recovers.
        guard let match = Stitch.match(previous, rows) else { return (out.count / bpr, true, false) }
        if match.scrolled > 0 {
            let (drop, range) = Stitch.splice(height: h, match)
            out.removeLast(drop * bpr)
            out.append(contentsOf: frame[(range.lowerBound * bpr)..<(range.upperBound * bpr)])
            last = rows
        }
        let height = out.count / bpr
        return (height, false, height >= Self.maxRows)
    }

    func image() -> CGImage? {
        guard bytesPerRow > 0, !out.isEmpty, let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: out.count / bytesPerRow, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Full-screen layer: first a crosshair to drag out the area, then a frame around it that lets
/// scrolling and clicks fall through to the app underneath.
private final class Overlay: NSWindow {
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private let view: OverlayView

    init(screen: NSScreen) {
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
        view.onDone = { [weak self] rect in
            guard let self else { return }
            self.onSelect?(NSRect(origin: NSPoint(x: rect.minX + self.frame.minX, y: rect.minY + self.frame.minY), size: rect.size))
        }
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?() } else { super.keyDown(with: event) }
    }

    /// Switch from choosing to capturing: dim only around the area, and stop catching the mouse.
    func capture(_ screenRect: NSRect) {
        ignoresMouseEvents = true
        view.capturing = true
        view.selection = NSRect(origin: NSPoint(x: screenRect.minX - frame.minX, y: screenRect.minY - frame.minY), size: screenRect.size)
        view.needsDisplay = true
    }
}

private final class OverlayView: NSView {
    var selection: NSRect?
    var capturing = false
    var onDone: ((NSRect) -> Void)?
    private var start: NSPoint?

    override func resetCursorRects() { if !capturing { addCursorRect(bounds, cursor: .crosshair) } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(capturing ? 0.35 : 0.22).setFill()
        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.append(NSBezierPath(rect: selection).reversed) // a hole where the area is
        }
        dim.fill()
        if let selection {
            (capturing ? NSColor.systemGreen : NSColor.white).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -1.5, dy: -1.5))
            border.lineWidth = 2
            border.stroke()
        }
        if !capturing, selection == nil {
            let hint = "Drag over the area you want to scroll  ·  Esc to cancel" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 9, width: size.width + 32, height: size.height + 18)
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            hint.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 9), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        guard let selection, selection.width >= 60, selection.height >= 60 else { // a stray click: start over
            selection = nil
            needsDisplay = true
            return
        }
        onDone?(selection.integral)
    }
}

/// The pill under the area while capturing.
private struct ScrollControls: View {
    let status: ScrollCapture.Status
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.lost ? "exclamationmark.triangle.fill" : "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.lost ? .yellow : .white.opacity(0.8))
                .symbolEffect(.bounce, value: status.pixels / 400)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: status.pixels)
            Spacer(minLength: 0)
            Button("Cancel", action: cancel).font(.system(size: 11, weight: .medium)).buttonStyle(IslandButtonStyle())
            Button("Done", action: done).font(.system(size: 11, weight: .semibold)).buttonStyle(IslandButtonStyle(tint: .green))
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 44)
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var message: String {
        if status.lost { return "Too fast — scroll back up a little" }
        if status.pixels == 0 { return "Starting…" }
        return "Scroll down · \(status.pixels.formatted()) px"
    }
}

/// One global shortcut (⌥⇧⌘4) for scroll capture. Carbon's hot keys need no Accessibility permission.
enum Hotkey {
    nonisolated(unsafe) private static var action: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        guard ref == nil else { return }
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey | optionKey),
                            EventHotKeyID(signature: OSType(0x5350_5243), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
