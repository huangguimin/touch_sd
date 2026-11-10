import AppKit
import FingerUI
import SwiftUI

@main
struct SDFingerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Touch SD", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.vault)
                .environmentObject(state.actions)
                .environmentObject(state.slide)
                .frame(minWidth: 860, minHeight: 600)
                .onAppear { delegate.state = state }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window(CameraView.title, id: "camera") {
            CameraView(camera: state.camera).environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
                .environmentObject(state.vault)
                .environmentObject(state.actions)
        } label: {
            MenuBarLabel(paired: state.pairedCard != nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always start with the main window, whatever was open when the app quit.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
        if dock { NSApp.activate(ignoringOtherApps: true) }
    }

    // The menu bar icon keeps the card, unlock actions and sudo working with no window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state?.shutdown() }
    }
}

/// The menu bar icon.  It exists from launch on, so it is also what opens the main
/// window at start (SwiftUI would otherwise restore "no window" if it was closed last).
struct MenuBarLabel: View {
    let paired: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var opened = false

    /// The card's tail end on, as on the app icon: the shell with its round ears, the sensor
    /// in the middle (filled once paired) and the LED at each ear.  A template, so the menu
    /// bar tints it.
    static func tail(paired: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 14), flipped: false) { _ in
            NSColor.black.set()
            let shell = NSBezierPath(roundedRect: NSRect(x: 1, y: 3.5, width: 24, height: 7), xRadius: 3.5, yRadius: 3.5)
            shell.lineWidth = 1.4
            shell.stroke()
            // 14.5 of the 26.3 mm
            let sensor = NSBezierPath(roundedRect: NSRect(x: 6.4, y: 5.2, width: 13.2, height: 3.6), xRadius: 1.8, yRadius: 1.8)
            if paired {
                sensor.fill()
            } else {
                sensor.lineWidth = 1.1
                sensor.stroke()
            }
            for x in [4.5, 21.5] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: 5.8, width: 2.4, height: 2.4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Image(nsImage: MenuBarLabel.tail(paired: paired))
            .onAppear {
                guard !opened else { return }
                opened = true
                if UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true {
                    openWindow(id: "main")
                }
            }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var vault: Vault
    @EnvironmentObject var actions: Actions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.statusLine)
        if let f = app.feedback, Date().timeIntervalSince(f.at) < 60 {
            Text("\(f.title)  \(f.detail)")
        }
        Divider()
        Button("打开 Touch SD") { open(.home) }
        Button(vault.state == .open ? "保险箱（已打开）" : "打开保险箱…") { open(.vault) }
            .disabled(vault.state == .none)
        Toggle("按指纹时执行解锁动作", isOn: $actions.enabled)
        Divider()
        Button("退出 Touch SD") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ p: Page) {
        app.page = p
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { app.page }, set: { if let p = $0 { app.page = p } })) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(12) }
        } detail: {
            ScrollView {
                Group {
                    switch app.page {
                    case .home: HomePage()
                    case .fingers: FingersPage()
                    case .vault: VaultPage()
                    case .actions: ActionsPage()
                    case .sudo: SudoPage()
                    case .dev: DeveloperPage()
                    case .slide: SlidePage()
                    case .device: DevicePage()
                    case .security: SecurityPage()
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: Binding(get: { app.pairing != nil }, set: { if !$0 { app.cancelPairing() } })) {
            PairingSheet()
        }
        .sheet(isPresented: Binding(get: { app.enroll != nil }, set: { if !$0 { app.cancelEnroll() } })) {
            EnrollSheet()
        }
        .alert("Touch SD", isPresented: Binding(get: { app.alertText != nil }, set: { if !$0 { app.alertText = nil } })) {
            Button("好") { app.alertText = nil }
        } message: {
            Text(app.alertText ?? "")
        }
    }
}

/// Card state at the bottom of the sidebar.
struct SidebarStatus: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(app.pairedCard != nil ? Color.green : app.identity != nil ? Color.orange : Color.secondary)
                .frame(width: 8, height: 8)
            Text(app.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if app.touching {
                Image(systemName: "hand.point.up.left.fill").font(.caption).foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: shared pieces

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }
}

struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}

/// The fingerprint glyph, lit while a finger is on the sensor.
struct TouchGlyph: View {
    let active: Bool
    var size: CGFloat = 64
    var waiting = false
    @State private var pulse = false

    var body: some View {
        Image(systemName: "touchid")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(active ? Color.accentColor : waiting ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.6))
            .scaleEffect(waiting && pulse ? 1.06 : 1)
            .animation(waiting ? .easeInOut(duration: 0.9).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

struct FeedbackLine: View {
    let feedback: Feedback?

    var body: some View {
        if let f = feedback {
            HStack(spacing: 6) {
                Image(systemName: f.tone == .ok ? "checkmark.circle.fill" : f.tone == .fail ? "xmark.circle.fill" : "info.circle")
                    .foregroundStyle(f.tone == .ok ? .green : f.tone == .fail ? .red : .secondary)
                Text(f.title).bold()
                if !f.detail.isEmpty { Text(f.detail).foregroundStyle(.secondary) }
            }
            .transition(.opacity)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
