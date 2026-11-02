import SwiftUI

/// Spruce's look, taken from the capture pill: near-black surfaces, white type, monospaced
/// filenames, capsule buttons that brighten on hover, green for done, yellow for keep, red for delete.
/// Every window uses these pieces so the app feels like one object.
enum Theme {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.047) // #0B0B0C
    static let sidebar = Color(red: 0.027, green: 0.027, blue: 0.031)    // a step darker
    static let card = Color.white.opacity(0.055)
    static let cardBorder = Color.white.opacity(0.07)
    static let field = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let selected = Color.white.opacity(0.11)

    static let text = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    static let success = Color(red: 0.19, green: 0.82, blue: 0.35) // the island's check
    static let keep = Color.yellow
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)

    // Type: SF Pro Rounded for the name and headings (its round ends match the pill shapes),
    // SF Pro for body text, SF Mono for filenames. All built into macOS: nothing to bundle or license.
    static let wordmark = Font.system(size: 15, weight: .bold, design: .rounded)
    static let title = Font.system(size: 21, weight: .bold, design: .rounded)
    static let label = Font.system(size: 13, weight: .medium)
    static let detail = Font.system(size: 11.5)
    static let sectionHeader = Font.system(size: 10.5, weight: .bold, design: .rounded)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let button = Font.system(size: 12, weight: .medium)
}

/// A settings page: title, one-line description, then sections.
struct ThemePage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.title).foregroundStyle(Theme.text)
                    if let subtitle { Text(subtitle).font(Theme.detail).foregroundStyle(Theme.secondary) }
                }
                content
            }
            .padding(.horizontal, 26)
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

/// A group of rows on a dark card, with a small caps header and an optional footnote.
struct ThemeSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased()).font(Theme.sectionHeader).tracking(0.8).foregroundStyle(Theme.tertiary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardBorder))
            if let footer {
                Text(footer).font(Theme.detail).foregroundStyle(Theme.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Label (with optional explanation) on the left, a control on the right.
struct ThemeRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.label).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(Theme.detail).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

/// A switch row, green when on like the island's check.
struct ThemeToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        ThemeRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.success).controlSize(.small)
        }
    }
}

/// Text field on a dark rounded plate; monospaced for filenames, paths and model names.
struct ThemeFieldStyle: TextFieldStyle {
    var mono = false
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono : .system(size: 12.5))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The main action in a window: a white capsule with black text.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : hovering ? 1 : 0.9)))
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .opacity(enabled ? 1 : 0.35)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// A list row that highlights softly on hover.
struct HoverRow: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The app's mark: a tiny black island with a green dot, used in window headers.
struct IslandMark: View {
    var body: some View {
        Capsule().fill(.black)
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .overlay(alignment: .trailing) { Circle().fill(Theme.success).frame(width: 5, height: 5).padding(.trailing, 5) }
            .frame(width: 30, height: 13)
    }
}

/// The app lives in the menu bar with no Dock icon. While one of its windows is open it shows a Dock
/// icon, so the window can be found in the Dock and ⌘Tab; the icon goes away when the last one closes.
@MainActor
enum DockIcon {
    static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        // Wait for the closing window to be gone before counting what's left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let anyOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            if !anyOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// Add to each window's root view.
struct ShowsDockIcon: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { DockIcon.windowOpened() }
            .onDisappear { DockIcon.windowClosed() }
    }
}
