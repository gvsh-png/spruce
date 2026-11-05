import AppKit
import SwiftUI

@main
struct ScreenshotRenamerApp: App {
    @State private var state = AppState()

    init() {
        // One Spruce at a time: two would each show a pill and rename every screenshot twice.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(state)
        } label: {
            // Bounces when a screenshot lands; shows a check for a moment after each rename.
            Image(systemName: state.justRenamed ? "checkmark.circle" : state.status.symbol)
                .symbolEffect(.bounce, value: state.captureCount)
                .contentTransition(.symbolEffect(.replace))
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsView().environment(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Screenshots", id: "manager") {
            ManagerView().environment(state)
        }
        .defaultSize(width: 980, height: 680)
        .windowStyle(.hiddenTitleBar)

        Window("Rename Screenshots", id: "bulk") {
            BulkView().environment(state)
        }
        .defaultSize(width: 720, height: 520)
        .windowStyle(.hiddenTitleBar)
    }
}

extension AppState.Status {
    var symbol: String {
        switch self {
        case .watching: "camera.viewfinder"
        case .processing: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        }
    }
}

private func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

// MARK: Menu bar popover

struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        Text(statusText)
        if let problem {
            Text(problem)
        }
        Toggle("Rename New Screenshots", isOn: $state.prefs.watching)
        Toggle("Open at Login", isOn: $state.prefs.openAtLogin)

        Divider()

        Menu("Recent") {
            if state.history.isEmpty {
                Text("No renames yet")
            }
            ForEach(state.history.prefix(10)) { entry in
                Menu(fileName(entry.to)) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.to)]) }
                    Button("Copy") { AppState.copyToClipboard(URL(fileURLWithPath: entry.to)) }
                    if state.willExpire(entry) {
                        Button("Keep") { state.keep(entry) }
                    }
                    Divider()
                    Button("Undo Rename") { state.undo([entry]) }
                }
            }
        }
        Button(undoTitle) { state.undoLast() }
            .keyboardShortcut("z")
            .disabled(state.history.isEmpty)

        Divider()

        Button("Scroll Capture…") { ScrollCapture.shared.start(state) }
            .keyboardShortcut("4", modifiers: [.command, .shift, .option])
        Button("Manage Screenshots…") {
            openWindow(id: "manager")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("m")
        Button("Rename Old Screenshots…") {
            openWindow(id: "bulk")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            .disabled(!Updater.shared.canCheck)

        Divider()

        Button("Quit Spruce") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var undoTitle: String {
        let n = state.lastGroup.count
        return n > 1 ? "Undo Last Rename (\(n) files)" : "Undo Last Rename"
    }

    private var statusText: String {
        switch state.status {
        case .processing: state.queued > 0 ? "Renaming… \(state.queued) waiting" : "Renaming…"
        case .watching: "Renaming new screenshots in \(state.prefs.watchFolders.map(fileName).joined(separator: ", "))"
        case .paused: "Paused"
        }
    }

    /// One short line when something needs attention; details live in Settings.
    private var problem: String? {
        if !state.unreadableFolders.isEmpty { return "⚠︎ Can't open \(state.unreadableFolders.map(fileName).joined(separator: ", ")). Allow it in Privacy & Security → Files and Folders." }
        if let error = state.lastError { return "⚠︎ " + (error.count > 70 ? String(error.prefix(70)) + "…" : error) }
        return nil
    }
}

// MARK: Settings window

private func folderLabel(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var page: Page = .general

    enum Page: String, CaseIterable, Identifiable {
        case general, island, ai, sorting, privacy, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .island: "Island"
            case .ai: "AI"
            case .sorting: "Sorting"
            case .privacy: "Private Apps"
            case .history: "History"
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .island: "capsule.tophalf.filled"
            case .ai: "sparkles"
            case .sorting: "folder"
            case .privacy: "hand.raised"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.cardBorder).frame(width: 1)
            Group {
                switch page {
                case .general: GeneralPage()
                case .island: IslandPage()
                case .ai: AIPage()
                case .sorting: SortingPage()
                case .privacy: PrivacyPage()
                case .history: HistoryPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .transition(.opacity)
            .id(page)
        }
        .animation(.easeOut(duration: 0.15), value: page)
        .frame(width: 740, height: 540)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.success)
        .modifier(ShowsDockIcon())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                IslandMark()
                Text("Spruce").font(Theme.wordmark).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10).padding(.bottom, 14)

            ForEach(Page.allCases) { item in
                SidebarItem(title: item.title, icon: item.icon, selected: page == item) { page = item }
            }
        }
        .padding(.top, 44) // room for the window buttons
        .padding(.bottom, 16)
        .padding(.horizontal, 10)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

private struct SidebarItem: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 16)
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct GeneralPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ThemePage(title: "General", subtitle: "Where screenshots come from and how they're named.") {
            ThemeSection(title: "Watched folders",
                         footer: "macOS saves screenshots to \(folderLabel(Preferences.systemScreenshotFolder)).") {
                ForEach(state.prefs.watchFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.secondary).font(.system(size: 12))
                        Text(folderLabel(path)).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { state.prefs.watchFolders.removeAll { $0 == path } }
                            .font(Theme.button).buttonStyle(IslandButtonStyle(tint: Theme.danger))
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        for url in panel.urls where !state.prefs.watchFolders.contains(url.path) { state.prefs.watchFolders.append(url.path) }
                    }
                }
                .font(Theme.button).buttonStyle(IslandButtonStyle())
            }

            ThemeSection(title: "Startup") {
                ThemeToggle(title: "Open at login", detail: "Starts Spruce when you log in, so new screenshots are always named.",
                            isOn: $state.prefs.openAtLogin)
            }

            ThemeSection(title: "Names") {
                ThemeRow(title: "Style", detail: example) {
                    Picker("Style", selection: $state.prefs.style) {
                        ForEach(NamingStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                ThemeToggle(title: "Include the date", detail: "Adds 2026-11-02 at the start, so names sort by time.", isOn: $state.prefs.includeDate)
            }

            ThemeSection(title: "After a screenshot") {
                ThemeToggle(title: "Copy to clipboard", detail: "Ready to paste the moment it's saved.", isOn: $state.prefs.copyToClipboard)
                ThemeToggle(title: "Notification with Undo",
                            detail: state.prefs.showPanel ? "Used when the island is off, and for bulk renames." : "Shown because the island is off.",
                            isOn: $state.prefs.notify)
            }

            ThemeSection(title: "Clean up") {
                ThemeToggle(title: "Temporary by default",
                            detail: "Screenshots go to the Trash after \(state.prefs.expireDays) days unless you keep, rename or move them.",
                            isOn: $state.prefs.expireEnabled)
                ThemeRow(title: "Keep for", detail: "The Trash holds them another 30 days.") {
                    Stepper("\(state.prefs.expireDays) days", value: $state.prefs.expireDays, in: 1...90)
                        .font(Theme.mono).foregroundStyle(Theme.text)
                }
                .disabled(!state.prefs.expireEnabled)
                .opacity(state.prefs.expireEnabled ? 1 : 0.4)
                ThemeToggle(title: "Collapse bursts",
                            detail: "Several shots of the same thing within a minute: keep the last one.",
                            isOn: $state.prefs.collapseBursts)
            }

            UpdatesSection()

            ThemeSection(title: "Other screenshot apps",
                         footer: "Screenshots from macOS are recognized automatically, in any language.") {
                ThemeToggle(title: "Also match by filename", detail: "For CleanShot, Shottr and similar.", isOn: $state.prefs.matchByName)
                TextField("Prefixes", text: $state.prefs.namePrefixes, prompt: Text("Screenshot, CleanShot"))
                    .textFieldStyle(ThemeFieldStyle(mono: true))
                    .disabled(!state.prefs.matchByName)
                    .opacity(state.prefs.matchByName ? 1 : 0.4)
            }
        }
    }

    private var example: String {
        let stem = TextRules.stem(words: ["slack", "alice", "q3", "budget"], style: state.prefs.style,
                                  date: state.prefs.includeDate ? Date() : nil) ?? ""
        return stem + ".png"
    }
}

struct IslandPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ThemePage(title: "Island", subtitle: "The black pill that drops in under the menu bar after each screenshot.") {
            ThemeSection {
                ThemeToggle(title: "Show the pill", detail: "Shows the name and quick actions for each new screenshot.", isOn: $state.prefs.showPanel)
            }
            Group {
                ThemeSection(title: "Timing", footer: "Counted from when the name appears. Hovering or editing pauses it.") {
                    ThemeRow(title: "Close after") {
                        HStack(spacing: 10) {
                            Slider(value: $state.prefs.islandSeconds, in: 1...10, step: 0.5).frame(width: 180)
                            Text("\(state.prefs.islandSeconds, specifier: "%.1f") s").font(Theme.mono).monospacedDigit()
                                .foregroundStyle(Theme.text).frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                ThemeSection(title: "Preview") {
                    ThemeToggle(title: "Larger preview on hover", detail: "Rest the pointer on the thumbnail.", isOn: $state.prefs.peekEnabled)
                    ThemeRow(title: "Hover for") {
                        HStack(spacing: 10) {
                            Slider(value: $state.prefs.peekDelay, in: 0.1...1.5, step: 0.05).frame(width: 180)
                            Text("\(state.prefs.peekDelay, specifier: "%.2f") s").font(Theme.mono).monospacedDigit()
                                .foregroundStyle(Theme.text).frame(width: 44, alignment: .trailing)
                        }
                    }
                    .disabled(!state.prefs.peekEnabled)
                    .opacity(state.prefs.peekEnabled ? 1 : 0.4)
                }
                ThemeSection(title: "Sensitive text", footer: "Emails, phone and card numbers, IBANs and API keys. Found and covered on your Mac.") {
                    ThemeToggle(title: "Offer to redact sensitive text",
                                detail: "Adds Redact to the pill: one click covers them and copies the result.",
                                isOn: $state.prefs.offerRedact)
                    ThemeRow(title: "Cover with") {
                        Picker("Cover with", selection: $state.prefs.redactStyle) {
                            ForEach(RedactStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .disabled(!state.prefs.offerRedact)
                    .opacity(state.prefs.offerRedact ? 1 : 0.4)
                }
                ThemeSection(title: "Feel", footer: "Animations calm down when Reduce Motion is on in System Settings → Accessibility.") {
                    ThemeToggle(title: "Bouncy opening", isOn: $state.prefs.bouncy)
                    ThemeToggle(title: "Trackpad tick", detail: "When a name is applied.", isOn: $state.prefs.haptic)
                }
            }
            .disabled(!state.prefs.showPanel)
            .opacity(state.prefs.showPanel ? 1 : 0.4)
        }
    }
}

struct AIPage: View {
    @Environment(AppState.self) private var state
    @State private var key = Keychain.get() ?? ""
    @State private var keySaved = false

    var body: some View {
        @Bindable var state = state
        ThemePage(title: "AI", subtitle: "Which model writes the names. Text is read on this Mac first.") {
            ThemeSection(footer: providerHelp) {
                ThemeRow(title: "Provider") {
                    Picker("Provider", selection: $state.prefs.provider) {
                        ForEach(ProviderMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                ThemeRow(title: "Apple on-device model") {
                    HStack(spacing: 6) {
                        Circle().fill(Namer.appleAvailable ? Theme.success : Theme.tertiary).frame(width: 7, height: 7)
                        Text(Namer.appleAvailable ? "Ready" : "Not available").font(Theme.detail).foregroundStyle(Theme.secondary)
                    }
                }
            }
            ThemeSection(title: "Ollama", footer: "Install from ollama.com, then run: ollama pull \(state.prefs.ollamaModel)") {
                ThemeRow(title: "Server") { TextField("Server", text: $state.prefs.ollamaURL).textFieldStyle(ThemeFieldStyle(mono: true)).frame(width: 260) }
                ThemeRow(title: "Model") { TextField("Model", text: $state.prefs.ollamaModel).textFieldStyle(ThemeFieldStyle(mono: true)).frame(width: 260) }
            }
            ThemeSection(title: "Cloud API", footer: "Only the extracted text is sent, and only after you add a key. The key is stored in your Keychain.") {
                ThemeRow(title: "Server") { TextField("Server", text: $state.prefs.cloudURL).textFieldStyle(ThemeFieldStyle(mono: true)).frame(width: 260) }
                ThemeRow(title: "Model") { TextField("Model", text: $state.prefs.cloudModel).textFieldStyle(ThemeFieldStyle(mono: true)).frame(width: 260) }
                ThemeRow(title: "API key") {
                    HStack(spacing: 8) {
                        SecureField("Paste key", text: $key).textFieldStyle(ThemeFieldStyle(mono: true)).frame(width: 180)
                        Button(keySaved ? "Saved" : "Save") { Keychain.set(key); keySaved = true }
                            .font(Theme.button).buttonStyle(IslandButtonStyle(tint: keySaved ? Theme.success : .white))
                    }
                }
                .onChange(of: key) { keySaved = false }
                ThemeToggle(title: "Send a small image", detail: "Only when a screenshot has almost no text.", isOn: $state.prefs.allowCloudImages)
            }
        }
    }

    private var providerHelp: String {
        switch state.prefs.provider {
        case .auto: "Apple's on-device model if available, then Ollama if it's running, then the cloud API only if you added a key."
        case .apple: "Runs fully on this Mac. Needs Apple Intelligence turned on."
        case .ollama: "Runs fully on this Mac. Ollama must be running."
        case .cloud: "Sends screenshot text to the server below."
        }
    }
}

struct SortingPage: View {
    @Environment(AppState.self) private var state
    @State private var newFolder = ""

    var body: some View {
        @Bindable var state = state
        ThemePage(title: "Sorting", subtitle: "Folders and Finder tags.") {
            ThemeSection(footer: "The AI picks one of your folders or none. It never makes up folders. They're created next to the screenshot.") {
                ThemeToggle(title: "Move into folders", isOn: $state.prefs.sortingEnabled)
            }
            ThemeSection(title: "Folders") {
                ForEach(state.prefs.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.secondary).font(.system(size: 12))
                        Text(folder).font(Theme.mono).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { state.prefs.folders.removeAll { $0 == folder } }
                            .font(Theme.button).buttonStyle(IslandButtonStyle(tint: Theme.danger))
                    }
                }
                HStack(spacing: 8) {
                    TextField("New folder, e.g. Work/Slack", text: $newFolder).textFieldStyle(ThemeFieldStyle(mono: true)).onSubmit(add)
                    Button("Add", action: add).font(Theme.button).buttonStyle(IslandButtonStyle())
                        .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .disabled(!state.prefs.sortingEnabled)
            .opacity(state.prefs.sortingEnabled ? 1 : 0.4)
            ThemeSection(title: "Finder tags", footer: TextRules.kinds.filter { $0 != "Other" }.joined(separator: " · ")) {
                ThemeToggle(title: "Tag each screenshot by kind", isOn: $state.prefs.tagsEnabled)
            }
        }
    }

    private func add() {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(".."), !state.prefs.folders.contains(name) else { return }
        state.prefs.folders.append(name)
        newFolder = ""
    }
}

struct PrivacyPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ThemePage(title: "Private Apps",
                  subtitle: "Screenshots taken while one of these is in front keep their name. Nothing is read or sent to any AI.") {
            ThemeSection {
                ForEach(state.prefs.privateApps, id: \.self) { id in
                    HStack(spacing: 10) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                                .font(Theme.label).foregroundStyle(Theme.text)
                        } else {
                            Image(systemName: "app.dashed").foregroundStyle(Theme.tertiary).frame(width: 20)
                            Text(id).font(Theme.mono).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Button("Remove") { state.prefs.privateApps.removeAll { $0 == id } }
                            .font(Theme.button).buttonStyle(IslandButtonStyle(tint: Theme.danger))
                    }
                }
                Button("Add App…") {
                    let open = NSOpenPanel()
                    open.allowedContentTypes = [.application]
                    open.allowsMultipleSelection = true
                    open.directoryURL = URL(fileURLWithPath: "/Applications")
                    guard open.runModal() == .OK else { return }
                    for url in open.urls {
                        if let id = Bundle(url: url)?.bundleIdentifier, !state.prefs.privateApps.contains(id) { state.prefs.privateApps.append(id) }
                    }
                }
                .font(Theme.button).buttonStyle(IslandButtonStyle())
            }
        }
    }
}

struct HistoryPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ThemePage(title: "History", subtitle: "\(state.history.count) renames. Undo puts the old name back.") {
            if state.history.isEmpty {
                ThemeSection {
                    Text("Take a screenshot and it shows up here.").font(Theme.detail).foregroundStyle(Theme.secondary)
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(state.history.prefix(200)) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileName(entry.to)).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Text("\(fileName(entry.from)) · \(entry.provider) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Theme.detail).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.to)]) }
                                .font(Theme.button).buttonStyle(IslandButtonStyle())
                            Button("Undo") { state.undo([entry]) }
                                .font(Theme.button).buttonStyle(IslandButtonStyle())
                        }
                        .modifier(HoverRow())
                    }
                }
            }
        }
    }
}

/// Version, update switches and a manual check, in the General page.
struct UpdatesSection: View {
    @State private var updater = Updater.shared

    var body: some View {
        ThemeSection(title: "Updates", footer: lastCheckText) {
            ThemeRow(title: "Spruce \(Updater.version)") {
                Button("Check Now") { updater.checkForUpdates() }
                    .font(Theme.button).buttonStyle(IslandButtonStyle())
                    .disabled(!updater.canCheck)
            }
            ThemeToggle(title: "Check for updates automatically", detail: "Once a day.",
                        isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
            ThemeToggle(title: "Download and install automatically", detail: "Installs the next time Spruce quits.",
                        isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                .disabled(!updater.automaticallyChecks)
                .opacity(updater.automaticallyChecks ? 1 : 0.4)
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return "Not checked yet." }
        return "Last checked " + date.formatted(.relative(presentation: .named)) + "."
    }
}
