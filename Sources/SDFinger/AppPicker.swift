import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstalledApp: Identifiable, Hashable {
    let path: String
    let name: String
    var id: String { path }
}

enum InstalledApps {
    /// What Launchpad would show: the app folders, and suites one folder down.
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var paths = Set<String>()
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let p = root + "/" + entry
                if entry.hasSuffix(".app") {
                    paths.insert(p)
                    continue
                }
                var dir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { continue }
                for inner in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where inner.hasSuffix(".app") {
                    paths.insert(p + "/" + inner)
                }
            }
        }
        return paths.map { InstalledApp(path: $0, name: fm.displayName(atPath: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The chosen app, as a button that opens the list.
struct AppField: View {
    @Binding var path: String
    @State private var picking = false

    private var chosen: Bool { path.hasSuffix(".app") }
    private var missing: Bool { chosen && !FileManager.default.fileExists(atPath: path) }

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 6) {
                if chosen {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 16, height: 16)
                }
                Text(!chosen ? "选择应用…" : missing ? "找不到这个应用，重新选择…"
                     : FileManager.default.displayName(atPath: path))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $picking) { AppPickerSheet(path: $path) }
    }
}

struct AppPickerSheet: View {
    @Binding var path: String
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var search = ""

    private var shown: [InstalledApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func choose(_ p: String) {
        path = p
        dismiss()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let u = panel.url { choose(u.path) }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("搜索应用", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = shown.first { choose(first.path) } }
            List(shown) { a in
                Button { choose(a.path) } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.path))
                            .resizable().frame(width: 20, height: 20)
                        Text(a.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay { if apps.isEmpty { ProgressView() } }
            HStack {
                Button("其他位置…") { browse() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 360, height: 460)
        .task { apps = await Task.detached { InstalledApps.scan() }.value }
    }
}
