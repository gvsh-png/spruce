import SwiftUI

/// Bulk rename: preview a name for every old screenshot, untick or edit any, then apply as one undoable batch.
struct BulkView: View {
    @Environment(AppState.self) private var state
    @State private var folder = URL(fileURLWithPath: Preferences.systemScreenshotFolder, isDirectory: true)

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.bulk.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List($state.bulk) { $p in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $p.include).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                TextField("Name", text: $p.stem).textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                                Text(".\(p.url.pathExtension.lowercased())").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Text(p.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if p.dir != p.url.deletingLastPathComponent() {
                            Label(p.dir.lastPathComponent, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                        }
                        if let kind = p.kind { Text(kind).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                    }
                    .opacity(p.include ? 1 : 0.45)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 440)
        .modifier(ShowsDockIcon())
        .onAppear { if state.bulk.isEmpty && !state.bulkRunning { state.scanForBulk(folder) } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename old screenshots").font(Theme.title)
                Text((folder.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Folder…") {
                let open = NSOpenPanel()
                open.canChooseDirectories = true
                open.canChooseFiles = false
                open.directoryURL = folder
                if open.runModal() == .OK, let url = open.url {
                    folder = url
                    state.scanForBulk(url)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var empty: some View {
        if state.bulkRunning {
            ProgressView("Reading the first screenshot…")
        } else if state.bulkTotal == 0 {
            ContentUnavailableView("Nothing to rename", systemImage: "checkmark.circle",
                                   description: Text("No screenshots with their original system name in this folder."))
        } else {
            ContentUnavailableView("Done", systemImage: "checkmark.circle", description: Text("Renamed. Use Undo Last in the menu bar to revert the whole batch."))
        }
    }

    private var footer: some View {
        HStack {
            if state.bulkRunning {
                ProgressView(value: Double(state.bulkDone), total: Double(max(state.bulkTotal, 1))).frame(width: 160)
                Text("\(state.bulkDone) of \(state.bulkTotal) named").font(.callout).monospacedDigit()
                Button("Stop") { state.stopBulk() }
            } else if state.bulkTotal > 0 {
                Text("\(state.bulk.count) named").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            let count = state.bulk.filter(\.include).count
            Button("Rename \(count) \(count == 1 ? "File" : "Files")") { state.applyBulk() }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
        }
        .padding(14)
    }
}
