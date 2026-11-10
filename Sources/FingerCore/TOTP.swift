import CryptoKit
import Foundation

/// Time-based one-time passwords (RFC 6238) for two-step verification.  Takes the Base32
/// secret a site shows, or the whole otpauth:// link from its QR code.
public struct TOTP: Equatable {
    public enum Algorithm { case sha1, sha256, sha512 }
    public let secret: Data
    public let digits: Int
    public let period: Int
    public let algorithm: Algorithm

    public init?(_ text: String) {
        var base32 = text
        var digits = 6, period = 30
        var algorithm = Algorithm.sha1
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("otpauth://") {
            guard let items = URLComponents(string: t)?.queryItems,
                  let s = items.first(where: { $0.name.lowercased() == "secret" })?.value else { return nil }
            base32 = s
            for i in items {
                switch i.name.lowercased() {
                case "digits": digits = Int(i.value ?? "") ?? digits
                case "period": period = Int(i.value ?? "") ?? period
                case "algorithm":
                    switch i.value?.uppercased() {
                    case "SHA256": algorithm = .sha256
                    case "SHA512": algorithm = .sha512
                    default: break
                    }
                default: break
                }
            }
        }
        guard let key = TOTP.base32(base32), !key.isEmpty, (6...8).contains(digits), period > 0 else { return nil }
        secret = key
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    public init(secret: Data, digits: Int, period: Int, algorithm: Algorithm) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = Data()
        var bits = 0, value = 0
        for ch in s.uppercased() where ch != " " && ch != "-" && ch != "=" {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            value = value << 5 | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(value >> bits & 0xFF))
                value &= (1 << bits) - 1
            }
        }
        return out
    }

    public func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let msg = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        }
        let off = Int(mac[mac.count - 1] & 0x0F)
        let n = UInt32(mac[off] & 0x7F) << 24 | UInt32(mac[off + 1]) << 16 | UInt32(mac[off + 2]) << 8 | UInt32(mac[off + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        return String(format: "%0\(digits)u", n % mod)
    }

    public func secondsLeft(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }
}
