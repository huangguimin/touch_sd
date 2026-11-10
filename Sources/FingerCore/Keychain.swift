import Foundation
import Security

/// Generic-password items in the login keychain, readable only on this Mac while it is
/// unlocked (kSecAttrAccessibleWhenUnlockedThisDeviceOnly).  The item's access list is
/// bound to the code signature of the app that created it, so another program (or a
/// re-signed copy of this one) gets a system prompt instead of the secret.
public enum Keychain {
    /// The product's old name.  Pairing keys live under it, so it stays.
    public static let service = "SD Finger"

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func get(_ account: String) throws -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw failure("读取", st) }
        return out as? Data
    }

    public static func set(_ account: String, _ data: Data) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecSuccess { return }
        guard st == errSecItemNotFound else { throw failure("更新", st) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "\(service): \(account)"
        let st2 = SecItemAdd(add as CFDictionary, nil)
        guard st2 == errSecSuccess else { throw failure("保存", st2) }
    }

    public static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    public static func accounts(prefix: String) -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// A random 32-byte key under `account`, created on first use.
    public static func key(_ account: String) throws -> Data {
        if let k = try get(account), k.count == 32 { return k }
        var k = Data(count: 32)
        let st = k.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard st == errSecSuccess else { throw Failure(description: "系统随机数不可用") }
        try set(account, k)
        return k
    }

    static func failure(_ what: String, _ st: OSStatus) -> Failure {
        let msg = SecCopyErrorMessageString(st, nil) as String? ?? "\(st)"
        return Failure(description: "钥匙串\(what)失败：\(msg)")
    }
}

/// A card this Mac is paired with: what SecureCard.open needs, plus the card's identity
/// pinned at pairing (trust on first use).
public struct PairedCard: Codable, Equatable {
    public var name: String
    public let serial: Data
    public let publicKey: Data
    public let hostId: Data
    public let kPair: Data
    public let paired: Date

    public init(name: String, pairing: SecureCard.Pairing) {
        self.name = name
        serial = pairing.card.serial
        publicKey = pairing.card.publicKey
        hostId = pairing.hostId
        kPair = SecureCard.pairingKey(pairing)
        paired = Date()
    }

    public var fingerprint: String {
        SecureCard.Identity(protocolVersion: 2, developmentImage: false, slotsUsed: 0, slots: 0,
                            serial: serial, publicKey: publicKey).fingerprint
    }

    public func matches(_ id: SecureCard.Identity) -> Bool {
        id.serial == serial && id.publicKey == publicKey
    }

    static func account(_ prefix: String, _ serial: Data) -> String { prefix + serial.hexString }

    public static func all(prefix: String = "card:") -> [PairedCard] {
        Keychain.accounts(prefix: prefix).compactMap {
            (try? Keychain.get($0)).flatMap { $0 }.flatMap { try? JSONDecoder().decode(PairedCard.self, from: $0) }
        }
    }

    public static func find(_ id: SecureCard.Identity, prefix: String = "card:") -> PairedCard? {
        guard let d = try? Keychain.get(account(prefix, id.serial)),
              let c = try? JSONDecoder().decode(PairedCard.self, from: d) else { return nil }
        return c
    }

    public func save(prefix: String = "card:") throws {
        try Keychain.set(PairedCard.account(prefix, serial), try JSONEncoder().encode(self))
    }

    public func forget(prefix: String = "card:") {
        Keychain.delete(PairedCard.account(prefix, serial))
    }
}
