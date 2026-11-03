import AppKit
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Scroll capture: drag over a scrollable area, scroll through it as usual, press Done. A 30 fps
/// ScreenCaptureKit stream of just that area feeds the stitcher, which keeps only the rows that
/// scrolled into view. The result is saved into the screenshot folder and named like any other.
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
    private var stream: SCStream?
    private var sink: FrameSink?
    private var stitcher: Stitcher?
    /// Frames are stitched here, one at a time, off the main thread.
    private let queue = DispatchQueue(label: "spruce.scroll-capture", qos: .userInteractive)
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

        let stitcher = Stitcher(scrollbarPixels: Int(16 * screen.backingScaleFactor))
        self.stitcher = stitcher
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        // ScreenCaptureKit measures from the display's top-left corner, in points.
        let source = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        let sink = FrameSink(stitcher: stitcher) { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.stitcher === stitcher else { return }
                self.status.pixels = progress.height
                self.status.lost = progress.missed
                if progress.full { self.status.full = true; self.stop(save: true) }
            }
        }
        self.sink = sink

        Task { [weak self] in
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
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // fast flicks still overlap
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.showsCursor = false
                guard let self, self.stitcher === stitcher else { return }
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = stream
                try await stream.startCapture()
            } catch {
                self?.state?.lastError = "Scroll capture stopped: \(error.localizedDescription)"
                self?.stop(save: false)
            }
        }
    }

    func stop(save: Bool) {
        let stream = self.stream
        self.stream = nil
        sink = nil
        overlay?.orderOut(nil)
        overlay = nil
        controls?.orderOut(nil)
        controls = nil
        let stitcher = self.stitcher
        self.stitcher = nil
        let folder = state.map { URL(fileURLWithPath: $0.prefs.watchFolders.first ?? Preferences.systemScreenshotFolder, isDirectory: true) }
        let queue = self.queue
        Task { [weak state] in
            try? await stream?.stopCapture() // no frames arrive after this
            guard save, let stitcher, let folder else { return }
            // Building and encoding a tall PNG takes a moment; do it on the stitching queue.
            let saved: Result<URL, Error>? = await withCheckedContinuation { done in
                queue.async { done.resume(returning: stitcher.image().map { image in Result { try Self.write(image, into: folder) } }) }
            }
            if case .failure(let error) = saved {
                state?.lastError = "Couldn't save the scroll capture: \(error.localizedDescription)"
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

/// Receives the stream's frames on the stitching queue.
private final class FrameSink: NSObject, SCStreamOutput {
    let stitcher: Stitcher
    let report: (Stitcher.Progress) -> Void

    init(stitcher: Stitcher, report: @escaping (Stitcher.Progress) -> Void) {
        self.stitcher = stitcher
        self.report = report
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames carry pixels; idle ones just say nothing changed.
        guard type == .screen, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = buffer.imageBuffer else { return }
        report(stitcher.add(pixels))
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
        if status.lost { return "Missed a bit — scroll up slightly" }
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
