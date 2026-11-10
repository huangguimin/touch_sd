import CryptoKit
import CvBridge
import Foundation

/// The key of the fingers file, kept wrapped for each paired card: opening it takes the
/// card's answer for the salt and this Mac's own key.  The Mac alone cannot, and neither
/// can the card.  Only the wrapped form is on disk.
public final class StoreKeys {
    struct Entry: Codable {
        var salt: Data
        var box: Data
    }

    private let url: URL
    private var entries: [String: Entry]

    public init(url: URL) {
        self.url = url
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func wrapKey(_ secret: Data, _ local: Data, _ salt: Data) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret + local), salt: salt,
                               info: Data("fpcard fingers v1".utf8), outputByteCount: 32)
    }

    /// The salt to ask this card about: the one its key was wrapped with, or a new one.
    public func salt(card: String) -> Data {
        if let e = entries[card] { return e.salt }
        var s = Data(count: 32)
        s.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return s
    }

    public func has(card: String) -> Bool { entries[card] != nil }

    public func open(card: String, secret: Data, local: Data) -> Data? {
        guard let e = entries[card], let box = try? ChaChaPoly.SealedBox(combined: e.box),
              let key = try? ChaChaPoly.open(box, using: StoreKeys.wrapKey(secret, local, e.salt),
                                             authenticating: Data(card.utf8)) else { return nil }
        return key
    }

    public func add(card: String, key: Data, salt: Data, secret: Data, local: Data) throws {
        let box = try ChaChaPoly.seal(key, using: StoreKeys.wrapKey(secret, local, salt), authenticating: Data(card.utf8))
        entries[card] = Entry(salt: salt, box: box.combined)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func removeAll() {
        entries = [:]
        try? FileManager.default.removeItem(at: url)
    }
}

/// Enrolled fingers for the product app: one file, sealed with ChaCha20-Poly1305 under a
/// key held by StoreKeys (docs/SECURITY_DESIGN.md section 6).  Without the paired card
/// and this Mac's keychain the file is noise.  The samples inside are
/// the 152 x 35 raw images the matcher works from, so the file is sensitive and never
/// leaves the Mac.
///
/// File: "SDFT" | version 1 | ChaChaPoly combined (nonce | ciphertext | tag) of the JSON
/// [{id, name, created, samples: [base64 raw]}].  The magic and version are the AAD.
public final class SealedStore {
    public let url: URL
    public private(set) var fingers: [Finger] = []
    private var key: SymmetricKey
    private var params: FPParams
    static let header = Data("SDFT".utf8) + Data([1])

    struct Record: Codable {
        let id: Int
        var name: String
        let created: String
        var samples: [Data]
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Loads `url` if it exists.  A file that does not open with this key is an error,
    /// not an empty store: it is never overwritten by accident.
    public init(url: URL, key: Data, params: FPParams) throws {
        self.url = url
        self.key = SymmetricKey(data: key)
        self.params = params
        guard let blob = try? Data(contentsOf: url) else { return }
        guard blob.count > 5 + 28, blob.prefix(5) == SealedStore.header,
              let box = try? ChaChaPoly.SealedBox(combined: blob.dropFirst(5)),
              let plain = try? ChaChaPoly.open(box, using: self.key, authenticating: SealedStore.header),
              let records = try? JSONDecoder().decode([Record].self, from: plain)
        else {
            throw Failure(description: "指纹库打不开（密钥不对或文件损坏）：\(url.path)")
        }
        for r in records {
            let g = Finger(id: r.id, name: r.name, created: r.created, files: [])
            g.samples = r.samples.map { FPSample(raw: $0, params: params) }
            fingers.append(g)
        }
    }

    /// Seal the file under a new key.
    public func rekey(_ data: Data) throws {
        key = SymmetricKey(data: data)
        try save()
    }

    private func save() throws {
        let records = fingers.map { Record(id: $0.id, name: $0.name, created: $0.created,
                                           samples: $0.samples.map(\.raw)) }
        let plain = try JSONEncoder().encode(records)
        let box = try ChaChaPoly.seal(plain, using: key, authenticating: SealedStore.header)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try (SealedStore.header + box.combined).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    public func add(_ samples: [FPSample], name: String? = nil) throws -> Finger {
        let id = (fingers.map(\.id).max() ?? 0) + 1
        let used = Set(fingers.map(\.name))
        var k = 1
        while used.contains("指纹 \(k)") { k += 1 }
        let g = Finger(id: id, name: name ?? "指纹 \(k)", created: Stamp.human(), files: [])
        g.samples = samples
        fingers.append(g)
        try save()
        return g
    }

    /// Adaptive update: an accepted unlock press joins the finger's template.
    public func append(_ g: Finger, _ s: FPSample) throws {
        g.samples.append(s)
        try save()
    }

    public func rename(_ g: Finger, _ name: String) throws {
        g.name = name
        try save()
    }

    public func remove(_ g: Finger) throws {
        fingers.removeAll { $0 === g }
        try save()
    }

    public func removeAll() throws {
        fingers.removeAll()
        try save()
    }

    public func recompute(_ p: FPParams) {
        params = p
        for g in fingers {
            g.samples = g.samples.map { FPSample(raw: $0.raw, params: p) }
        }
    }
}

/// Persistent unlock failures (docs/SECURITY_DESIGN.md 7.3): 20 failed attempts in total
/// and fingerprints stop working until the Mac's own password is entered.  Kept in the
/// keychain so quitting the app does not reset it.
public enum UnlockGuard {
    static let account = "unlock-failures"
    public static let limit = 20

    public static var failures: Int {
        (try? Keychain.get(account)).flatMap { $0 }.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    }

    public static var blocked: Bool { failures >= limit }

    public static func fail() {
        try? Keychain.set(account, Data(String(failures + 1).utf8))
    }

    public static func reset() {
        try? Keychain.set(account, Data("0".utf8))
    }
}

/// The vault's key wrapping (docs/SECURITY_DESIGN.md 7.2).  The protecting key needs the
/// card's answer r = HMAC(K_unlock, salt), which only the paired card can compute and
/// only after a real press, and a key from this Mac's keychain.
public enum VaultCrypto {
    public static func protectKey(cardSecret r: Data, local: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: r + local), salt: salt,
                               info: Data("fpcard vault v1".utf8), outputByteCount: 32)
    }

    public static func seal(_ data: Data, _ key: SymmetricKey, aad: String) throws -> Data {
        try ChaChaPoly.seal(data, using: key, authenticating: Data(aad.utf8)).combined
    }

    public static func open(_ blob: Data, _ key: SymmetricKey, aad: String) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob) else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: Data(aad.utf8))
    }

    /// 32 bytes as 8 groups of 7 characters (Crockford base32, no padding), for a
    /// recovery key someone writes down.
    public static func recoveryString(_ key: Data) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits = 0, acc = 0
        var out = ""
        for b in key {
            acc = acc << 8 | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(acc >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 7).map { i -> String in
            let s = out.index(out.startIndex, offsetBy: i)
            let e = out.index(s, offsetBy: min(7, out.count - i))
            return String(out[s..<e])
        }.joined(separator: "-")
    }

    public static func parseRecovery(_ text: String) -> Data? {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var acc = 0, bits = 0
        var out = Data()
        for c in text.uppercased() where c != "-" && c != " " {
            let c2: Character = c == "O" ? "0" : (c == "I" || c == "L") ? "1" : c
            guard let v = alphabet.firstIndex(of: c2) else { return nil }
            acc = (acc << 5 | v) & 0xFFFF
            bits += 5
            if bits >= 8 {
                out.append(UInt8((acc >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out.count == 32 ? out : nil
    }
}
