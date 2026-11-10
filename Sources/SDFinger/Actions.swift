import AppKit
@preconcurrency import FingerCore
import FingerUI
import Foundation

/// Something to do after an unlock with the card.
struct UnlockAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        // login keeps the name it was saved under: a .text action used to be lock screen only
        // unless switched, and Actions.init moves the switched ones to .typed
        case app, open, shortcut, totp, login = "text", typed, script

        var label: String {
            switch self {
            case .app: return "打开应用"
            case .open: return "打开网址或文件"
            case .shortcut: return "运行快捷指令"
            case .totp: return "输入两步验证码"
            case .login: return "输入登录密码"
            case .typed: return "自动键入文字"
            case .script: return "运行 shell 命令"
            }
        }
        var placeholder: String {
            switch self {
            case .app: return ""
            case .open: return "https://… 或文件路径"
            case .shortcut: return "快捷指令的名字"
            case .totp, .login, .typed: return ""
            case .script: return "例如 open -a Mail"
            }
        }
        var holdsText: Bool { self == .login || self == .typed }
    }

    var id = UUID()
    var kind: Kind
    var value: String
    var enabled = true
    /// Only this finger triggers it; nil is any finger.  The id survives a rename.
    var fingerId: Int?
    /// .totp: value is the vault item's id, this its title while the vault is locked.
    /// .login, .typed: value only says it is set, the text is in the keychain.
    var title: String?
    /// .login, .typed: press Return after it.  A login action does unless told not to.
    var enter: Bool?
    /// Saved by older versions: false made a text action type anywhere.
    var lockedOnly: Bool?

    var pressesEnter: Bool { enter ?? (kind == .login) }
}

/// The unlock actions: off unless the user turns them on; run in order on each accepted
/// press while nothing else (enrolment, the vault, sudo) is waiting for the finger.
@MainActor
final class Actions: ObservableObject {
    @Published var enabled: Bool { didSet { save() } }
    @Published var list: [UnlockAction] { didSet { save() } }
    @Published private(set) var lastRun = ""
    /// The current code of a vault item.
    var code: ((UUID) -> String?)?

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "actions.enabled")
        let saved = (d.data(forKey: "actions.list")).flatMap { try? JSONDecoder().decode([UnlockAction].self, from: $0) } ?? []
        // apps used to be typed in as a path under .open
        list = saved.map { a in
            var a = a
            if a.kind == .open && a.value.hasSuffix(".app") { a.kind = .app }
            if a.kind == .login && a.lockedOnly == false { a.kind = .typed }
            a.lockedOnly = nil
            if a.kind.holdsText && Actions.text(of: a) == nil { a.value = "" }
            return a
        }
    }

    private static func account(_ a: UnlockAction) -> String { "action-text:" + a.id.uuidString }

    static let maxText = 256

    /// What a .login or .typed action types.  In the keychain, as it can be a password.
    static func text(of a: UnlockAction) -> String? {
        (try? Keychain.get(account(a))).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
    }

    func setText(_ text: String, for id: UUID) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        try? Keychain.set(Actions.account(list[i]), Data(text.utf8))
        list[i].value = text.isEmpty ? "" : "set"
    }

    func remove(_ a: UnlockAction) {
        if a.kind.holdsText { Keychain.delete(Actions.account(a)) }
        list.removeAll { $0.id == a.id }
    }

    private func save() {
        UserDefaults.standard.set(enabled, forKey: "actions.enabled")
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "actions.list")
    }

    private func applies(_ a: UnlockAction, _ fingerId: Int?) -> Bool {
        a.enabled && !a.value.trimmingCharacters(in: .whitespaces).isEmpty && (a.fingerId == nil || a.fingerId == fingerId)
            && Actions.allowed(a.kind)
    }

    /// A password never reaches a window, and text never reaches the password field.
    private nonisolated static func allowed(_ kind: UnlockAction.Kind) -> Bool {
        switch kind {
        case .login: return screenLocked
        case .typed: return !screenLocked
        default: return true
        }
    }

    nonisolated static var screenLocked: Bool {
        let d = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (d?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// This press needs the vault open first.
    func needsVault(fingerId: Int?) -> Bool {
        enabled && list.contains { $0.kind == .totp && applies($0, fingerId) }
    }

    func run(finger: String?, fingerId: Int?) {
        guard enabled else { return }
        var done: [String] = []
        for a in list where applies(a, fingerId) {
            switch a.kind {
            case .totp:
                if let id = UUID(uuidString: a.value), let c = code?(id) { KeySender.type(c) }
            case .login, .typed:
                if let t = Actions.text(of: a) {
                    let kind = a.kind
                    KeySender.typeAwake(t, enter: a.pressesEnter, while: { Actions.allowed(kind) })
                }
            case .app:
                NSWorkspace.shared.open(URL(fileURLWithPath: a.value))
            case .shortcut:
                launch("/usr/bin/shortcuts", ["run", a.value])
            case .script:
                launch("/bin/zsh", ["-lc", a.value], env: ["SD_FINGER_FINGER": finger ?? ""])
            case .open:
                let v = a.value.trimmingCharacters(in: .whitespaces)
                if let u = URL(string: v), u.scheme != nil, !v.hasPrefix("/") {
                    NSWorkspace.shared.open(u)
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: (v as NSString).expandingTildeInPath))
                }
            }
            let what = a.kind == .app ? FileManager.default.displayName(atPath: a.value)
                : a.kind == .totp ? (a.title ?? "") : a.kind.holdsText ? "••••" : a.value
            done.append(a.kind.label + "：" + what)
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lastRun = done.isEmpty ? "" : f.string(from: Date()) + "  " + done.joined(separator: "；")
    }

    private func launch(_ path: String, _ args: [String], env: [String: String] = [:]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
