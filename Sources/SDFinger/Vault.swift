import AppKit
import CryptoKit
@preconcurrency import FingerCore
import Foundation

struct VaultItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var account: String
    var secret: String
    var note: String
    var updated = Date()
    var totp: String?      // Base32 secret or otpauth:// link

    var code: TOTP? { totp.flatMap { TOTP($0) } }
}

/// On disk (vault.json): the salt the card's secret is asked for, the vault key wrapped by
/// the protecting key (docs/SECURITY_DESIGN.md 7.2), and the items sealed by the vault key.
struct VaultFile: Codable {
    var version = 1
    var salt: Data
    var wrappedKey: Data
    var items: Data
    var cardSerial: Data
    var created = Date()
}

/// Secrets that open only with a matching finger on the paired card, on this Mac.
@MainActor
final class Vault: ObservableObject {
    enum State: Equatable {
        case none, locked, open
    }

    @Published private(set) var state = State.none
    @Published private(set) var items: [VaultItem] = []
    @Published var recoveryKeyToShow: String?

    let url: URL
    private var file: VaultFile?
    private var key: SymmetricKey?
    private var lastUse = Date()
    private var timer: Timer?
    static let autoLock: TimeInterval = 120

    init(directory: URL) {
        url = directory.appendingPathComponent("vault.json")
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(VaultFile.self, from: d) {
            file = f
            state = .locked
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .open,
                      Date().timeIntervalSince(self.lastUse) > Vault.autoLock else { return }
                self.lock()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                  NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            }
        }
    }

    var salt: Data? { file?.salt }

    private func localKey() throws -> Data { try Keychain.key("vault-local-key") }

    private func save() throws {
        guard let file else { return }
        let d = try JSONEncoder().encode(file)
        try d.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func sealItems(_ list: [VaultItem], _ k: SymmetricKey) throws -> Data {
        try VaultCrypto.seal(JSONEncoder().encode(list), k, aad: "fpcard vault items v1")
    }

    /// A new, empty vault under the card's answer for `salt`.  Returns the recovery key.
    func create(cardSecret r: Data, salt: Data, serial: Data) throws {
        var vk = Data(count: 32)
        vk.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let pk = VaultCrypto.protectKey(cardSecret: r, local: try localKey(), salt: salt)
        let k = SymmetricKey(data: vk)
        file = VaultFile(salt: salt, wrappedKey: try VaultCrypto.seal(vk, pk, aad: "fpcard vault key v1"),
                         items: try sealItems([], k), cardSerial: serial)
        try save()
        key = k
        items = []
        state = .open
        lastUse = Date()
        recoveryKeyToShow = VaultCrypto.recoveryString(vk)
    }

    func open(cardSecret r: Data) throws {
        guard let file else { throw SecureCard.Failure("还没有保险箱") }
        let pk = VaultCrypto.protectKey(cardSecret: r, local: try localKey(), salt: file.salt)
        guard let vk = VaultCrypto.open(file.wrappedKey, pk, aad: "fpcard vault key v1") else {
            throw SecureCard.Failure("这张卡或这台 Mac 打不开这个保险箱（换过卡？可以用恢复密钥）")
        }
        try unlock(with: SymmetricKey(data: vk))
    }

    private func unlock(with k: SymmetricKey) throws {
        guard let file, let plain = VaultCrypto.open(file.items, k, aad: "fpcard vault items v1"),
              let list = try? JSONDecoder().decode([VaultItem].self, from: plain) else {
            throw SecureCard.Failure("保险箱内容解不开")
        }
        key = k
        items = list
        state = .open
        lastUse = Date()
    }

    /// Recovery: open with the written-down key, then (with a press on the current card)
    /// protect it again with `rewrap`.
    func open(recovery text: String) throws {
        guard let vk = VaultCrypto.parseRecovery(text) else { throw SecureCard.Failure("恢复密钥格式不对") }
        try unlock(with: SymmetricKey(data: vk))
    }

    /// Protect the open vault's key with this card and this Mac again (after recovery or a
    /// new card).
    func rewrap(cardSecret r: Data, salt: Data, serial: Data) throws {
        guard var f = file, let key else { throw SecureCard.Failure("保险箱没有打开") }
        let vk = key.withUnsafeBytes { Data($0) }
        let pk = VaultCrypto.protectKey(cardSecret: r, local: try localKey(), salt: salt)
        f.salt = salt
        f.cardSerial = serial
        f.wrappedKey = try VaultCrypto.seal(vk, pk, aad: "fpcard vault key v1")
        file = f
        try save()
    }

    var cardSerial: Data? { file?.cardSerial }

    func lock() {
        key = nil
        items = []
        if file != nil { state = .locked }
    }

    func touch() { lastUse = Date() }

    func upsert(_ item: VaultItem) throws {
        guard let key, var f = file else { return }
        var list = items
        var it = item
        it.updated = Date()
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = it } else { list.append(it) }
        f.items = try sealItems(list, key)
        file = f
        try save()
        items = list
        lastUse = Date()
    }

    func remove(_ id: UUID) throws {
        guard let key, var f = file else { return }
        let list = items.filter { $0.id != id }
        f.items = try sealItems(list, key)
        file = f
        try save()
        items = list
    }

    func destroy() {
        try? FileManager.default.removeItem(at: url)
        file = nil
        key = nil
        items = []
        state = .none
    }

    /// Copy, and clear the clipboard again after a minute if it still holds this.
    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        let change = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if pb.changeCount == change { pb.clearContents() }
        }
        lastUse = Date()
    }
}
