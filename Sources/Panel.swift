import AppKit
import SwiftUI

/// Our replacement for Apple's floating thumbnail: a black pill that drops in just under the menu bar
/// with the screenshot and its name. It never takes focus from the app you're working in.
@MainActor
final class CapturePanel {
    static let shared = CapturePanel()
    private var panel: NSPanel?
    private weak var state: AppState?

    /// Room for the widest, tallest (hovered) island.
    static let width: CGFloat = 440
    /// Tall enough for the hover preview; the empty part is transparent and lets clicks through.
    static let extraHeight: CGFloat = 330

    func show(_ state: AppState) {
        self.state = state
        guard let screen = NSScreen.main else { return }
        let geometry = IslandGeometry(screen: screen)
        let panel = self.panel ?? make(state)
        self.panel = panel
        panel.contentView = NSHostingView(rootView: IslandView(geometry: geometry).environment(state))
        let height = geometry.top + geometry.inset + Self.extraHeight
        panel.setFrame(NSRect(x: screen.frame.midX - Self.width / 2, y: screen.frame.maxY - height,
                              width: Self.width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    /// Lets the island shrink back into the notch before the window goes away.
    func hide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.state?.capture == nil else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func make(_ state: AppState) -> NSPanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar itself, so the island can grow out of the notch over it. Set after
        // isFloatingPanel, which resets the level to .floating.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        return panel
    }
}

/// A non-activating panel that can still take keyboard input when clicked (to edit the name).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// macOS pushes windows below the menu bar by default; the island has to sit in the notch itself.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// On a screen with a camera notch the island grows out of the notch, attached to the top edge.
/// Elsewhere it is a floating pill just under the menu bar, centered on the screen.
struct IslandGeometry {
    /// Size of the notch, nil on screens without one.
    var notch: CGSize?
    /// Width of the island before it opens: the notch itself, or a small pill.
    var closedWidth: CGFloat
    /// Distance from the top of the screen to the island: 0 at the notch, else below the menu bar.
    var top: CGFloat
    /// Empty band at the top of the island that sits behind the notch.
    var inset: CGFloat { notch?.height ?? 0 }

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        closedWidth = notch?.width ?? 160
        top = notch == nil ? max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 5 : 0
    }
}

struct IslandView: View {
    let geometry: IslandGeometry
    @Environment(AppState.self) private var state
    @State private var open = false
    @State private var name = ""
    @State private var hovering = false
    @State private var copied: String?
    @State private var peeking = false
    @State private var peekImage: NSImage?
    /// Hover state with a short grace period on exit, so brushing the edge doesn't flicker.
    @State private var showHover = false
    @State private var hoverExit: Task<Void, Never>?
    @State private var peekTask: Task<Void, Never>?
    /// True while the "Other Folder…" picker is open, so the pill doesn't close underneath it.
    @State private var choosingFolder = false
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let openWidth: CGFloat = 360
    /// Room for the extra Redact button; still inside `CapturePanel.width`.
    private let wideWidth: CGFloat = 412
    private let rowHeight: CGFloat = 46
    private let toolsHeight: CGFloat = 34

    var body: some View {
        let capture = state.capture
        let deleted = capture?.trashedURL != nil
        let showTools = open && (showHover || editing) && capture?.proposal != nil && !deleted
        let notched = geometry.notch != nil
        let height = open ? geometry.inset + rowHeight + (showTools ? toolsHeight : 0) : (geometry.notch?.height ?? rowHeight)
        let wide = offersRedact(capture)

        VStack(spacing: 8) {
            // Content is laid out top-down at full size and the island's frame reveals it.
            // The name row never moves; the buttons slide in underneath as the island grows.
            VStack(spacing: 0) {
                if let capture {
                    row(capture).frame(height: rowHeight)
                        .opacity(open ? 1 : 0)
                    tools(capture).frame(height: toolsHeight)
                        .opacity(showTools ? 1 : 0)
                        .offset(y: showTools ? 0 : -8)
                        .blur(radius: showTools ? 0 : 3)
                        .allowsHitTesting(showTools)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, geometry.inset)
            .padding(.horizontal, 14 + ears)
            .frame(width: (open ? (wide ? wideWidth : openWidth) : geometry.closedWidth) + ears * 2, height: height, alignment: .top)
            .background(shape.fill(.black))
            .clipShape(shape)
            // A hairline edge and soft shadow keep the pill readable over dark windows.
            // At the notch it is the notch's own black, with no edge; elsewhere a hairline keeps it readable.
            .overlay { if !notched { RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) } }
            .shadow(color: .black.opacity(notched && !open ? 0 : 0.35), radius: 12, y: 5)
            // At the notch it grows out of it; elsewhere it drops in from just above and fades.
            .opacity(open || notched ? 1 : 0)
            .offset(y: open || notched ? 0 : -10)
            .scaleEffect(open || notched ? 1 : 0.94, anchor: .top)
            .onHover(perform: hoverChanged)

            // Hover preview: a larger look at the capture, below the island.
            if open, peeking, let image = peekImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: openWidth, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).combined(with: .offset(y: -10)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))))
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, geometry.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One spring family for everything, so size, fade and slide move together.
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: peeking)
        .animation(state.prefs.bouncy && !reduceMotion ? .spring(response: 0.38, dampingFraction: 0.78) : .easeInOut(duration: 0.25), value: open)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: showTools)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: wide)
        // Delete eases out; Undo snaps straight back.
        .animation(deleted ? .spring(response: 0.34, dampingFraction: 0.85) : .snappy(duration: 0.18), value: deleted)
        // After Delete: show "Moved to Trash · Undo" briefly (paused by hover), then close.
        .task(id: capture?.trashedURL) {
            guard capture?.trashedURL != nil else { return }
            var idle = 0.0
            while idle < 2.0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                idle = hovering ? 0 : idle + 0.25
            }
            state.dismissCapture()
        }
        .onChange(of: capture?.url, initial: true) {
            // Next runloop, so the first appearance animates out of the notch too.
            DispatchQueue.main.async { open = state.capture != nil }
        }
        .onChange(of: capture?.proposal?.id, initial: true) { name = state.capture?.proposal?.stem ?? "" }
        .onChange(of: name) { if state.capture?.proposal != nil { state.capture?.edited = name } }
        // Redact and its Undo change the file: Peek decodes it again, and Copy shows what's on the clipboard.
        .onChange(of: capture?.redactedOriginal) {
            peekImage = nil
            if state.capture?.redactedOriginal != nil { copied = "image" } else if copied == "image" { copied = nil }
        }
        .task(id: capture?.proposal?.id) {
            guard capture?.proposal != nil else { return }
            var idle = 0.0
            while idle < state.prefs.islandSeconds {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                idle = (hovering || editing || choosingFolder) ? 0 : idle + 0.25
            }
            state.finishCapture(stem: name)
        }
        // Last resort: if naming hasn't finished in 45 s, close instead of waiting forever.
        .task(id: capture?.url) {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled, state.capture != nil, state.capture?.proposal == nil { state.dismissCapture() }
        }
        .onExitCommand { state.finishCapture(stem: name) }
        .environment(\.colorScheme, .dark)
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        hoverExit?.cancel()
        if inside {
            showHover = true
        } else {
            hoverExit = Task {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if !Task.isCancelled { showHover = false }
            }
        }
    }

    /// Fully rounded pill; the radius stays a pill as it grows taller on hover.
    /// Flares where the island meets the top edge, like the notch's own corners.
    private var ears: CGFloat { geometry.notch == nil ? 0 : 8 }

    /// Grows out of the notch on a notched screen; a round pill elsewhere.
    private var shape: AnyShape {
        geometry.notch == nil
            ? AnyShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            : AnyShape(NotchShape(ear: ears, bottom: open ? 23 : 10))
    }

    private func row(_ capture: Capture) -> some View {
        let deleted = capture.trashedURL != nil
        return HStack(spacing: 8) {
            ZStack {
                // The thumbnail tips over and drops away; a trash can bounces in where it was.
                Group {
                    if let image = capture.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 48, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .scaleEffect(deleted ? 0.25 : 1, anchor: .bottom)
                .rotationEffect(.degrees(deleted ? -20 : 0), anchor: .bottom)
                .offset(y: deleted ? 10 : 0)
                .opacity(deleted ? 0 : 1)

                Image(systemName: "trash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .scaleEffect(deleted ? 1 : 0.3)
                    .opacity(deleted ? 1 : 0)
                    .symbolEffect(.bounce, value: deleted)
            }
            .frame(width: 48, height: 30)
            .onTapGesture { NSWorkspace.shared.open(capture.appliedURL ?? capture.url) }
            .help("Click to open, drag into any app")
            // Drag into Slack, Mail, Finder…: the name is applied first, so the file arrives renamed.
            .onDrag {
                let url = state.applyCaptureNow(stem: name) ?? capture.url
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            // Peek after resting on the thumbnail for 0.4 s.
            .onHover { inside in
                peekTask?.cancel()
                if inside, state.prefs.peekEnabled {
                    // Decode the preview off the main thread while waiting, so it appears without a hitch.
                    let url = capture.appliedURL ?? capture.url
                    peekTask = Task {
                        // 800 px is plenty for a 220 pt preview; decoding the full 5K screenshot isn't.
                        async let image = Task.detached(priority: .userInitiated) {
                            OCR.thumbnail(of: url, maxPixel: 800).flatMap(NSImage.init(data:))
                        }.value
                        try? await Task.sleep(nanoseconds: UInt64(state.prefs.peekDelay * 1_000_000_000))
                        if Task.isCancelled { return }
                        if peekImage == nil { peekImage = await image }
                        peeking = true
                    }
                } else {
                    peeking = false
                }
            }

            if deleted {
                Text("Moved to Trash")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .transition(.opacity)
                Spacer(minLength: 0)
                Button("Undo") { state.undoTrash() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(IslandButtonStyle())
                    .transition(.opacity)
            } else if capture.proposal != nil {
                HStack(spacing: 1) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .focused($editing)
                        .onSubmit { state.finishCapture(stem: name) }
                    Text(".\(capture.url.pathExtension.lowercased())").foregroundStyle(.white.opacity(0.45))
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                if !capture.replaced.isEmpty {
                    Button { state.restoreReplaced() } label: {
                        Text("−\(capture.replaced.count) similar")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(IslandButtonStyle())
                    .help("An earlier screenshot of the same thing went to the Trash. Click to bring it back.")
                }
                if let code = capture.proposal?.codes.first {
                    QRButton(payload: code)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
            } else if let partial = capture.partial {
                // The name as the model writes it.
                Text(partial)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1).truncationMode(.head)
                    .contentTransition(.interpolate)
                    .animation(.easeOut(duration: 0.15), value: partial)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            } else {
                Text("Naming…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Redact shows only when OCR found something sensitive in this screenshot.
    private func offersRedact(_ capture: Capture?) -> Bool {
        state.prefs.offerRedact && !(capture?.proposal?.sensitive.isEmpty ?? true)
    }

    private func tools(_ capture: Capture) -> some View {
        HStack(spacing: 6) {
            if state.prefs.expireEnabled {
                IslandButton(title: "Keep", tint: .yellow) { state.finishCapture(stem: name, keep: true) }
                    .help("Never move this one to the Trash")
            }
            IslandButton(title: copied == "image" ? "Copied" : "Copy") {
                // The name is applied first, like a drag, so the file pastes renamed.
                let url = state.applyCaptureNow(stem: name) ?? capture.url
                copied = AppState.copyToClipboard(url) ? "image" : nil
            }
            IslandButton(title: copied == "text" ? "Copied" : "Copy Text") {
                AppState.copyText(capture.proposal?.text ?? "")
                copied = "text"
            }
            .disabled(capture.proposal?.text.isEmpty ?? true)
            if offersRedact(capture), let count = capture.proposal?.sensitive.count {
                let redacted = capture.redactedOriginal != nil
                IslandButton(title: redacted ? "Redacted" : "Redact \(count)") {
                    if redacted { state.undoRedact() } else { state.redactCapture() }
                }
                .help(redacted ? "Copied with \(count) hidden. Click to bring back the original." : "Hide emails, numbers and keys, then copy")
            }
            Menu {
                let here = capture.url.deletingLastPathComponent()
                ForEach(state.prefs.folders, id: \.self) { folder in
                    Button(folder) { state.finishCapture(stem: name, dir: here.appendingPathComponent(folder, isDirectory: true)) }
                }
                if !state.prefs.folders.isEmpty { Divider() }
                Button("Other Folder…") {
                    let open = NSOpenPanel()
                    open.canChooseDirectories = true
                    open.canChooseFiles = false
                    open.directoryURL = here
                    open.prompt = "Move Here"
                    NSApp.activate(ignoringOtherApps: true)
                    choosingFolder = true
                    defer { choosingFolder = false }
                    if open.runModal() == .OK, let dir = open.url { state.finishCapture(stem: name, dir: dir) }
                }
            } label: {
                // Menus ignore .font on their title; set it on the label so it matches the other buttons.
                Text("Move").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.system(size: 11, weight: .medium))
            .modifier(IslandHover())
            Spacer(minLength: 0)
            IslandButton(title: "Delete", tint: .red) { state.trashCapture() }
                .help("Move to Trash")
        }
        .padding(.bottom, 6)
    }
}

/// Shown when the screenshot has a QR code: opens a web link in the browser, copies anything else
/// (Wi-Fi details, plain text). The full contents show on hover before you click.
private struct QRButton: View {
    let payload: String
    @State private var copied = false

    private var link: URL? {
        guard let url = URL(string: payload), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var body: some View {
        Button {
            if let link { NSWorkspace.shared.open(link) } else { AppState.copyText(payload); copied = true }
        } label: {
            Label(link != nil ? "Open" : copied ? "Copied" : "Copy", systemImage: "qrcode")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.interpolate)
        }
        .buttonStyle(IslandButtonStyle())
        .help(link.map { "Open \($0.absoluteString)" } ?? "Copy the QR code's contents: \(payload)")
        .fixedSize()
    }
}

private struct IslandButton: View {
    let title: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.interpolate) // "Copy" → "Copied" cross-fades
                .fixedSize() // never "Copy Te…": the Spacer before Delete gives way instead
        }
        .buttonStyle(IslandButtonStyle(tint: tint))
    }
}

/// Capsule button for the island: brightens and lifts slightly on hover, squeezes on click.
struct IslandButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, tint: tint)
    }

    private struct Styled: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    Capsule().fill(tint == .white ? Color.white : tint)
                        .opacity(pressed ? 0.32 : hovering ? 0.22 : 0.12)
                )
                .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.18 : 0), lineWidth: 0.5))
                .scaleEffect(pressed ? 0.92 : hovering ? 1.04 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = enabled && $0 }
                .modifier(PointingHand(active: hovering))
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        }
    }
}

/// The same hover look for the Move menu, which can't take a ButtonStyle.
private struct IslandHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.white).opacity(hovering ? 0.22 : 0.12))
            .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.18 : 0), lineWidth: 0.5))
            .scaleEffect(hovering ? 1.04 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .modifier(PointingHand(active: hovering))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
    }
}

/// Pointing-hand cursor while `active`. Pops on disappear too, so a button that vanishes under the
/// pointer (Delete, the pill closing) never leaves the hand stuck.
private struct PointingHand: ViewModifier {
    let active: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { set(active) }
            .onDisappear { set(false) }
    }

    private func set(_ on: Bool) {
        guard on != pushed else { return }
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        pushed = on
    }
}

/// The notch's outline: flat against the top edge with small outward flares, rounded at the bottom.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat
    var animatableData: CGFloat {
        get { bottom }
        set { bottom = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let b = min(bottom, (rect.width - ear * 2) / 2, rect.height - ear)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + ear + b, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - ear - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - b), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
