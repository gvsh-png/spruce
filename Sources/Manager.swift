import AppKit
import QuickLookThumbnailing
import SwiftUI

/// One screenshot on disk, as the manager lists it.
struct ShotFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let size: Int
    let kept: Bool
    /// The folder it sits in, relative to its watched folder ("Screenshots", "Receipts", "Work/Slack").
    let folder: String
}

/// Screenshot Manager: browse every screenshot in the watched folders (including sorted and Kept
/// subfolders), select many, and move them to the Trash in one go, with Undo.
struct ManagerView: View {
    @Environment(AppState.self) private var state
    @State private var files: [ShotFile] = []
    @State private var selection = Set<URL>()
    @State private var anchor: URL?
    @State private var scope: Scope = .all
    @State private var search = ""
    @State private var loading = true
    @State private var undo: (count: Int, items: [(original: URL, trashed: URL)])?
    @State private var undoTask: Task<Void, Never>?
    @AppStorage("managerTileWidth") private var tileWidth = 180.0
    @AppStorage("managerGrouping") private var grouping: Grouping = .day
    /// Filtered, grouped and counted once per change of files, scope, search or grouping,
    /// not on every click: selection changes re-render the view, and libraries get big.
    @State private var shown: [ShotFile] = []
    @State private var days: [(day: Date, files: [ShotFile])] = []
    @State private var counts: [Scope: Int] = [:]

    /// How the grid is split into sections; each section header can select all of its screenshots.
    enum Grouping: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month"
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    /// What the sidebar shows: a time range, Kept, or one folder.
    enum Scope: Hashable {
        case all, today, week, old, kept, folder(String)

        var title: String {
            switch self {
            case .all: "All Screenshots"
            case .today: "Today"
            case .week: "This Week"
            case .old: "Older than 30 Days"
            case .kept: "Kept"
            case .folder(let name): name
            }
        }

        func matches(_ f: ShotFile) -> Bool {
            switch self {
            case .all: true
            case .today: Calendar.current.isDateInToday(f.date)
            case .week: f.date > Date().addingTimeInterval(-7 * 86_400)
            case .old: f.date < Date().addingTimeInterval(-30 * 86_400)
            case .kept: f.kept
            case .folder(let name): f.folder == name
            }
        }
    }

    private func refilter() {
        let all: [Scope] = [.all, .today, .week, .old, .kept] + folders.map(Scope.folder)
        counts = Dictionary(uniqueKeysWithValues: all.map { scope in (scope, files.count { scope.matches($0) }) })
        shown = files.filter { scope.matches($0) && (search.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search)) }
        // Newest group first (day, week or month); each group newest first.
        let cal = Calendar.current
        days = Dictionary(grouping: shown) { cal.dateInterval(of: grouping.component, for: $0.date)?.start ?? cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
        // Never act on screenshots you can't see.
        selection.formIntersection(shown.map(\.url))
    }

    /// Watched folders first, then their subfolders alphabetically.
    private var folders: [String] {
        let roots = Set(state.prefs.watchFolders.map { ($0 as NSString).lastPathComponent })
        return Set(files.map(\.folder)).sorted { a, b in
            roots.contains(a) != roots.contains(b) ? roots.contains(a) : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.cardBorder).frame(width: 1)
            VStack(spacing: 0) {
                header
                content
            }
            .overlay(alignment: .bottom) { bottomBar }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.success)
        .task { await reload() }
        .modifier(ShowsDockIcon())
        .onChange(of: scope) { selection = []; refilter() }
        .onChange(of: search) { refilter() }
        .onChange(of: grouping) { refilter() }
        // New, renamed or undone screenshots show up without pressing Refresh.
        .onChange(of: state.history.first?.id) { Task { await reload() } }
        .onKeyPress(.escape) { selection = []; return .handled }
        .onKeyPress(characters: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(shown.map(\.url))
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    IslandMark()
                    Text("Spruce").font(Theme.wordmark).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 10).padding(.bottom, 14)

                sidebarHeader("Show")
                scopeItem(.all, icon: "square.grid.2x2")
                scopeItem(.today, icon: "sun.max")
                scopeItem(.week, icon: "calendar")
                scopeItem(.old, icon: "clock.badge.exclamationmark")
                scopeItem(.kept, icon: "pin")

                if !folders.isEmpty {
                    sidebarHeader("Folders").padding(.top, 12)
                    ForEach(folders, id: \.self) { name in
                        scopeItem(.folder(name), icon: "folder")
                    }
                }
            }
            .padding(.top, 44) // room for the window buttons
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .frame(width: 210)
        .background(Theme.sidebar.ignoresSafeArea())
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(Theme.sectionHeader).tracking(0.8).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 10).padding(.bottom, 2)
    }

    private func scopeItem(_ item: Scope, icon: String) -> some View {
        ScopeRow(title: item.title, icon: icon, count: counts[item] ?? 0, selected: scope == item) {
            scope = item
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: where you are, and search.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scope.title).font(Theme.title).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(shown.count) screenshots · \(byteString(shown.reduce(0) { $0 + $1.size }))")
                        .font(Theme.detail).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    TextField("Search names", text: $search).textFieldStyle(.plain).font(Theme.mono).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.field, in: Capsule())
                .frame(width: 210)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .font(Theme.button).buttonStyle(IslandButtonStyle())
                    .keyboardShortcut("r")
                    .help("Refresh (⌘R)")
            }
            // Row 2: how it's grouped, selection, tile size.
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(Grouping.allCases) { g in
                        FilterChip(title: g.rawValue, selected: grouping == g) { grouping = g }
                    }
                }
                .padding(2)
                .background(Theme.field, in: Capsule())
                .fixedSize()
                .help("Group by")
                Button(selection.count == shown.count && !shown.isEmpty ? "Deselect All" : "Select All") {
                    selection = selection.count == shown.count ? [] : Set(shown.map(\.url))
                }
                .font(Theme.button).buttonStyle(IslandButtonStyle())
                .fixedSize()
                .disabled(shown.isEmpty)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    Slider(value: $tileWidth, in: 130...300).frame(width: 100).controlSize(.mini)
                    Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                .help("Tile size")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    // MARK: Grid grouped by day

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(Theme.success)
                Text(files.isEmpty ? "No screenshots in your watched folders." : "Nothing here.")
                    .font(Theme.label).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.day) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.4), spacing: 14)],
                                      alignment: .leading, spacing: 16) {
                                ForEach(group.files) { file in
                                    ShotCell(file: file, selected: selection.contains(file.url))
                                        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
                                        .onTapGesture { click(file) }
                                        .contextMenu {
                                            Button("Open") { NSWorkspace.shared.open(file.url) }
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                            Button("Copy") { AppState.copyToClipboard(file.url) }
                                            Divider()
                                            Button("Move to Trash") { trash([file.url]) }
                                        }
                                }
                            }
                            .padding(.horizontal, 22)
                        } header: {
                            dayHeader(group.day, group.files)
                        }
                    }
                }
                .padding(.bottom, 90) // clear the bottom bar
            }
        }
    }

    private func dayHeader(_ day: Date, _ dayFiles: [ShotFile]) -> some View {
        let all = dayFiles.allSatisfy { selection.contains($0.url) }
        return HStack(spacing: 10) {
            Text(dayTitle(day)).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            Text("\(dayFiles.count) · \(byteString(dayFiles.reduce(0) { $0 + $1.size }))").font(Theme.mono).foregroundStyle(Theme.tertiary)
            Spacer()
            Button(all ? "Deselect" : "Select") {
                let urls = dayFiles.map(\.url)
                if all { selection.subtract(urls) } else { selection.formUnion(urls) }
            }
            .font(.system(size: 11, weight: .medium)).buttonStyle(IslandButtonStyle())
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(Theme.background.opacity(0.96))
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        switch grouping {
        case .month:
            return day.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
        case .week:
            if cal.isDate(day, equalTo: Date(), toGranularity: .weekOfYear) { return "This week" }
            if let last = cal.date(byAdding: .weekOfYear, value: -1, to: Date()),
               cal.isDate(day, equalTo: last, toGranularity: .weekOfYear) { return "Last week" }
            return "Week of " + day.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
        case .day:
            break
        }
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.abbreviated)
                                      : .dateTime.day().month(.abbreviated).year())
    }

    /// Click toggles; Shift-click selects everything between the last click and this one.
    private func click(_ file: ShotFile) {
        let list = days.flatMap(\.files) // on-screen order
        if NSEvent.modifierFlags.contains(.shift), let anchor,
           let a = list.firstIndex(where: { $0.url == anchor }), let b = list.firstIndex(where: { $0.url == file.url }) {
            for f in list[min(a, b)...max(a, b)] { selection.insert(f.url) }
        } else if selection.contains(file.url) {
            selection.remove(file.url)
        } else {
            selection.insert(file.url)
        }
        anchor = file.url
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            if let undo {
                HStack(spacing: 12) {
                    Image(systemName: "trash.fill").foregroundStyle(.white.opacity(0.85))
                    Text("Moved \(undo.count) screenshot\(undo.count == 1 ? "" : "s") to the Trash")
                        .font(Theme.label).foregroundStyle(Theme.text)
                    Button("Undo") { restore() }.font(Theme.button).buttonStyle(IslandButtonStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.black))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !selection.isEmpty {
                let picked = files.filter { selection.contains($0.url) }
                HStack(spacing: 8) {
                    Text("\(picked.count) selected").font(Theme.label).foregroundStyle(Theme.text)
                    Text(byteString(picked.reduce(0) { $0 + $1.size })).font(Theme.mono).foregroundStyle(Theme.secondary)
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 4)
                    Button(selection.count == shown.count ? "Deselect All" : "Select All") {
                        selection = selection.count == shown.count ? [] : Set(shown.map(\.url))
                    }
                    .font(Theme.button).buttonStyle(IslandButtonStyle())
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(selection)) }
                        .font(Theme.button).buttonStyle(IslandButtonStyle())
                    Button("Keep") { keepSelection() }
                        .font(Theme.button).buttonStyle(IslandButtonStyle(tint: Theme.keep))
                        .help("Move to the Kept folder so they never expire")
                    Button("Delete") { deleteSelection() }
                        .font(Theme.button).buttonStyle(IslandButtonStyle(tint: Theme.danger))
                        .keyboardShortcut(.delete, modifiers: [])
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.black))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection.isEmpty)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: undo?.count)
    }

    // MARK: Actions

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        trash(Array(selection))
    }

    private func trash(_ urls: [URL]) {
        Task {
            // Hundreds of files take a moment: move them off the main thread.
            let moved = await Task.detached(priority: .userInitiated) { () -> [(original: URL, trashed: URL)] in
                urls.compactMap { url in
                    var trashed: NSURL?
                    guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil,
                          let t = trashed as URL? else { return nil }
                    return (url, t)
                }
            }.value
            finishTrash(moved)
        }
    }

    private func finishTrash(_ moved: [(original: URL, trashed: URL)]) {
        guard !moved.isEmpty else { return }
        Self.trashSound?.play()
        let gone = Set(moved.map(\.original))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            files.removeAll { gone.contains($0.url) }
            selection.subtract(gone)
            refilter()
        }
        // A second delete while Undo is still showing adds to it, so Undo brings back both.
        let items = (undo?.items ?? []) + moved
        undo = (items.count, items)
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { undo = nil }
        }
    }

    private func restore() {
        guard let items = undo?.items else { return }
        undoTask?.cancel()
        for (original, trashed) in items where !FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.moveItem(at: trashed, to: original)
        }
        undo = nil
        Task { await reload() }
    }

    private func keepSelection() {
        for url in selection where !XAttr.isKept(url) {
            if let entry = state.history.first(where: { $0.to == url.path }) {
                state.keep(entry)
            } else {
                _ = try? FileOps.keep(url, style: state.prefs.style)
            }
        }
        selection = []
        Task { await reload() }
    }

    /// Every screenshot in the watched folders, two levels deep (sorted folders and Kept included).
    private func reload() async {
        let folders = state.prefs.watchFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let prefixes = state.prefs.prefixList
        loading = files.isEmpty
        let found = await Task.detached(priority: .userInitiated) { () -> [ShotFile] in
            var out: [ShotFile] = []
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
            for folder in folders {
                guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in e {
                    if e.level > 2 { e.skipDescendants(); continue }
                    guard FolderWatcher.extensions.contains(url.pathExtension.lowercased()),
                          let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    let name = url.lastPathComponent
                    // Screenshots only: flagged by macOS, handled by this app, or still system-named.
                    guard XAttr.isScreenCapture(url) || XAttr.isDone(url) || TextRules.looksDefaultName(name)
                            || prefixes.contains(where: name.hasPrefix) else { continue }
                    let parent = url.deletingLastPathComponent().path
                    let folderName = parent == folder.path ? folder.lastPathComponent
                        : String(parent.dropFirst(folder.path.count + 1))
                    out.append(ShotFile(url: url, date: v.creationDate ?? .distantPast, size: v.fileSize ?? 0,
                                        kept: XAttr.isKept(url), folder: folderName))
                }
            }
            return out.sorted { $0.date > $1.date }
        }.value
        files = found
        refilter()
        loading = false
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true)
}

private func byteString(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize() // never wrap letter by letter when space is tight
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .black : Theme.secondary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.white : hovering ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// One tile: thumbnail, name and date. Lifts on hover; a green ring and check when selected.
private struct ShotCell: View {
    let file: ShotFile
    let selected: Bool
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                // Fixed 16:10 plate; the screenshot fits inside it, so wide or tall shots never spill out.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit().padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.success : .white.opacity(hovering ? 0.18 : 0.07), lineWidth: selected ? 2 : 0.5))

                ZStack {
                    Circle().fill(selected ? Theme.success : .black.opacity(0.45)).frame(width: 20, height: 20)
                    Circle().strokeBorder(.white.opacity(selected ? 0 : 0.7), lineWidth: 1.2).frame(width: 20, height: 20)
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
                }
                .padding(7)
                .opacity(selected || hovering ? 1 : 0)
                .scaleEffect(selected ? 1 : 0.9)

                if file.kept {
                    Text("Kept").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.keep))
                        .padding(7).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(file.date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hovering && !selected ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: selected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: file.url) { image = await Thumbnails.image(for: file.url) }
    }
}

/// QuickLook thumbnails, cached for the session. QuickLook reuses Finder's own cache, so this is fast.
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        // Big enough for the largest tile (300 pt × 1.4), so large tiles stay sharp.
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 420, height: 263),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.nsImage, forKey: url as NSURL)
        return rep.nsImage
    }
}

private struct ScopeRow: View {
    let title: String
    let icon: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
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
