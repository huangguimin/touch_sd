import CryptoKit
import Foundation

/// The secure channel to the card (docs/CARD_PROTOCOL.md, "加密会话";
/// docs/SECURITY_DESIGN.md).  Pairing agrees a key with X25519 and has
/// the user compare eight colours on the card's LEDs with the ones on screen; after that
/// every session is opened with that key and each message, and each fingerprint frame,
/// is sealed with ChaCha20-Poly1305 under per-session keys.
public enum SecureCard {
    static let protocolVersion: UInt8 = 3

    enum Packet: UInt8 {
        case ident = 0x03, pairInit = 0x10, pairConfirm = 0x11, pairCancel = 0x12, resetArm = 0x13, resetState = 0x14, resetCancel = 0x15, open = 0x20, sealed = 0x30
    }
    enum Inner: UInt8 {
        case ping = 0x01, secret = 0x02, sign = 0x03, unpair = 0x04, close = 0x05, sshPub = 0x06, sshSign = 0x07, live = 0x08, store = 0x09, led = 0x0A
    }
    static let encrypted: UInt16 = 0x0001

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ s: String) { description = s }
    }

    /// Public facts about a card.
    public struct Identity: Equatable {
        public let protocolVersion: Int
        public let developmentImage: Bool
        public let slotsUsed, slots: Int
        public let serial: Data            // 8 bytes, the chip's unique id
        public let publicKey: Data         // P-256, X || Y
        // what protects this card, from the card itself; all false on older firmware
        public var keysSealed = false
        public var secureBoot = false
        public var debugDisabled = false

        /// Short form for people: the first bytes of the key's SHA-256.
        public var fingerprint: String {
            SHA256.hash(data: publicKey).prefix(6).map { String(format: "%02X", $0) }
                .joined().enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? " \($0.element)" : "\($0.element)" }
                .joined()
        }
        public var serialHex: String { serial.hexString }
    }

    public static func identity(_ mb: CardMailbox) throws -> Identity {
        let r = try mb.request(type: Packet.ident.rawValue, payload: [])
        guard r.type == Packet.ident.rawValue | 0x80, r.body.count == 76 else {
            throw Failure("这张卡的固件不支持加密通信，请先升级固件")
        }
        let b = r.body
        var id = Identity(protocolVersion: Int(b[0]), developmentImage: b[1] & 1 != 0,
                          slotsUsed: Int(b[2]), slots: Int(b[3]),
                          serial: Data(b[4..<12]), publicKey: Data(b[12..<76]))
        id.keysSealed = b[1] & 2 != 0
        id.secureBoot = b[1] & 4 != 0
        id.debugDisabled = b[1] & 8 != 0
        return id
    }

    // MARK: pairing

    /// The colours, in the order the card blinks them.
    public enum SASColor: Int, CaseIterable {
        case red, green, blue, yellow, cyan, magenta
        public var name: String { ["红", "绿", "蓝", "黄", "青", "紫"][rawValue] }
        public var rgb: (Double, Double, Double) {
            [(1, 0, 0), (0, 0.8, 0), (0.1, 0.3, 1), (1, 0.75, 0), (0, 0.85, 0.9), (0.9, 0, 0.9)][rawValue]
        }
    }

    /// A pairing waiting for the user to compare colours and press the sensor.
    public struct Pairing {
        public let hostId: Data
        public let card: Identity
        public let colors: [SASColor]
        let transcript: Data
        let kPair: SymmetricKey
    }

    public enum ConfirmResult {
        case paired(Pairing)
        case waitingForPress
    }

    public static func beginPairing(_ mb: CardMailbox, hostId: Data) throws -> Pairing {
        precondition(hostId.count == 16)
        let card = try identity(mb)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let b = eph.publicKey.rawRepresentation
        var req = [protocolVersion]
        req += hostId
        req += b
        // X25519 and an ECDSA signature on the card take a moment.
        let r = try mb.request(type: Packet.pairInit.rawValue, payload: req, timeout: 8)
        guard r.type == Packet.pairInit.rawValue | 0x80, r.body.count == 168 else { throw Failure("配对应答格式不对") }
        let a = Data(r.body[0..<32]), idPub = Data(r.body[32..<96]), serial = Data(r.body[96..<104])
        let sig = Data(r.body[104..<168])
        guard idPub == card.publicKey, serial == card.serial else { throw Failure("卡的身份在配对中途变了") }
        var t = Data("fpcard pair v1".utf8)
        t.append(protocolVersion)
        t += hostId + b + serial + a + idPub
        let transcript = Data(SHA512.hash(data: t))
        let key = try P256.Signing.PublicKey(rawRepresentation: idPub)
        guard let s = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
              key.isValidSignature(s, for: SHA256.hash(data: transcript)) else {
            throw Failure("卡的签名验证失败，停止配对")
        }
        let z = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: a))
        let okm = z.hkdfDerivedSymmetricKey(using: SHA512.self, salt: transcript,
                                            sharedInfo: Data("fpcard pair v1".utf8), outputByteCount: 64)
        let k = okm.withUnsafeBytes { Data($0) }
        let colors = (0..<8).map { i -> SASColor in
            let v = Int(k[32 + 2 * i]) | Int(k[33 + 2 * i]) << 8
            return SASColor(rawValue: v % 6)!
        }
        return Pairing(hostId: hostId, card: card, colors: colors, transcript: transcript,
                       kPair: SymmetricKey(data: k.prefix(32)))
    }

    /// Tell the card the user saw the same colours.  The card also needs a press on its
    /// sensor; until then this answers `.waitingForPress` and should be called again.
    public static func confirm(_ mb: CardMailbox, _ p: Pairing) throws -> ConfirmResult {
        let mac = HMAC<SHA512>.authenticationCode(for: Data("fpcard confirm v1".utf8) + p.transcript, using: p.kPair)
        let r = try mb.request(type: Packet.pairConfirm.rawValue, payload: Array(p.hostId) + Array(Data(mac).prefix(32)),
                               timeout: 4)
        guard r.type == Packet.pairConfirm.rawValue | 0x80, let status = r.body.first else { throw Failure("配对应答格式不对") }
        switch status {
        case 0:
            let expect = HMAC<SHA512>.authenticationCode(for: Data("fpcard paired v1".utf8) + p.transcript, using: p.kPair)
            guard r.body.count == 33, constantTimeEqual(Data(r.body[1...]), Data(expect).prefix(32)) else {
                throw Failure("卡的确认码不对，配对作废")
            }
            return .paired(p)
        case 1: return .waitingForPress
        case 2: throw Failure("卡算出的密钥和这台 Mac 不一样（可能有人在中间），配对作废")
        case 3: throw Failure("卡上没有进行中的配对（超时了？）")
        default: throw Failure("卡没能保存配对")
        }
    }

    public static func cancelPairing(_ mb: CardMailbox) {
        _ = try? mb.request(type: Packet.pairCancel.rawValue, payload: [])
    }

    // MARK: factory reset

    public struct ResetState {
        public let armed: Bool
        public let holding: Bool
        public let done: UInt32
    }

    private static func reset(_ mb: CardMailbox, _ p: Packet) throws -> ResetState {
        let r = try mb.request(type: p.rawValue, payload: [])
        guard r.type == p.rawValue | 0x80, r.body.count == 6 else {
            throw Failure("这张卡的固件不支持在 App 里恢复出厂，请先升级固件")
        }
        let done = UInt32(r.body[2]) | UInt32(r.body[3]) << 8 | UInt32(r.body[4]) << 16 | UInt32(r.body[5]) << 24
        return ResetState(armed: r.body[0] != 0, holding: r.body[1] != 0, done: done)
    }

    /// The card then waits 30 s for a finger put down and held for 5 s.
    public static func armReset(_ mb: CardMailbox) throws -> ResetState { try reset(mb, .resetArm) }
    public static func resetState(_ mb: CardMailbox) throws -> ResetState { try reset(mb, .resetState) }
    public static func cancelReset(_ mb: CardMailbox) { _ = try? reset(mb, .resetCancel) }

    public static func pairingKey(_ p: Pairing) -> Data { p.kPair.withUnsafeBytes { Data($0) } }

    // MARK: sessions

    public static func open(_ mb: CardMailbox, hostId: Data, kPair: Data) throws -> Session {
        let kCmd = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: kPair), salt: Data(),
                                          info: Data("fpcard cmd v1".utf8), outputByteCount: 32)
        var nApp = Data(count: 16)
        nApp.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        // one-time keys on both sides: K_pair stolen later does not open what was recorded
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ePub = ephemeral.publicKey.rawRepresentation
        let mac = HMAC<SHA512>.authenticationCode(for: Data("fpcard open v1".utf8) + hostId + nApp + ePub, using: kCmd)
        let r = try mb.request(type: Packet.open.rawValue, payload: Array(hostId + nApp + ePub) + Array(Data(mac).prefix(32)))
        guard r.type == Packet.open.rawValue | 0x80, r.body.count == 80 else { throw Failure("会话应答格式不对") }
        let nCard = Data(r.body[0..<16]), eCard = Data(r.body[16..<48])
        let expect = HMAC<SHA512>.authenticationCode(for: Data("fpcard open-ok v1".utf8) + hostId + nApp + nCard + ePub + eCard,
                                                     using: kCmd)
        guard constantTimeEqual(Data(r.body[48..<80]), Data(expect).prefix(32)) else {
            throw Failure("卡的会话应答验证失败")
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: eCard))
        let ikm = kPair + shared.withUnsafeBytes { Data($0) }
        let keys = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: nApp + nCard,
                                          info: Data("fpcard session v2".utf8), outputByteCount: 104)
            .withUnsafeBytes { Data($0) }
        return Session(mailbox: mb, c2h: SymmetricKey(data: keys[0..<32]), h2c: SymmetricKey(data: keys[32..<64]),
                       img: SymmetricKey(data: keys[64..<96]), sid: Data(keys[96..<104]))
    }

    /// An open session.  Not thread safe; use from one queue.
    public final class Session {
        let mailbox: CardMailbox
        let c2h, h2c, img: SymmetricKey
        let sid: Data
        private var txCtr: UInt32 = 0
        private var rxCtr: UInt32 = 0
        private var imgCtr: UInt32 = 0
        public private(set) var lastUse = Date()
        public private(set) var closed = false

        init(mailbox: CardMailbox, c2h: SymmetricKey, h2c: SymmetricKey, img: SymmetricKey, sid: Data) {
            self.mailbox = mailbox
            self.c2h = c2h
            self.h2c = h2c
            self.img = img
            self.sid = sid
        }

        private func nonce(_ ctr: UInt32) -> ChaChaPoly.Nonce {
            var n = sid
            n.append(contentsOf: withUnsafeBytes(of: ctr.littleEndian, Array.init))
            return try! ChaChaPoly.Nonce(data: n)
        }

        func call(_ type: Inner, _ data: [UInt8] = [], timeout: TimeInterval = 3) throws -> [UInt8] {
            guard !closed else { throw Failure("会话已关闭") }
            txCtr &+= 1
            let box = try ChaChaPoly.seal(Data([type.rawValue] + data), using: h2c, nonce: nonce(txCtr),
                                          authenticating: CardMailbox.headerAAD(type: Packet.sealed.rawValue,
                                                                                flags: SecureCard.encrypted))
            var payload = withUnsafeBytes(of: txCtr.littleEndian, Array.init)
            payload += box.ciphertext + box.tag
            let r: (type: UInt8, flags: UInt16, body: [UInt8])
            do {
                r = try mailbox.request(type: Packet.sealed.rawValue, flags: SecureCard.encrypted, payload: payload,
                                        timeout: timeout)
            } catch let e as CardMailbox.Failure where e.description == "no session" || e.description == "sealed: refused" {
                closed = true
                throw Failure("会话已失效，需要重新建立")
            }
            guard r.type == Packet.sealed.rawValue | 0x80, r.flags & SecureCard.encrypted != 0, r.body.count >= 21 else {
                throw Failure("加密应答格式不对")
            }
            let ctr = r.body.u32(0)
            guard Int32(bitPattern: ctr &- rxCtr) > 0 else { throw Failure("应答计数器倒退，丢弃") }
            let sealed = try ChaChaPoly.SealedBox(nonce: nonce(ctr), ciphertext: r.body[4..<(r.body.count - 16)],
                                                  tag: r.body[(r.body.count - 16)...])
            guard let plain = try? ChaChaPoly.open(sealed, using: c2h,
                                                   authenticating: CardMailbox.headerAAD(type: r.type, flags: r.flags))
            else { throw Failure("应答认证失败，丢弃") }
            rxCtr = ctr
            lastUse = Date()
            let out = Array(plain)
            if out.first == 0xFF {
                throw Failure(String(decoding: out.dropFirst(), as: UTF8.self))
            }
            guard out.first == type.rawValue | 0x80 else { throw Failure("应答类型不对") }
            return Array(out.dropFirst())
        }

        public func ping() throws {
            let p = [UInt8]("keepalive".utf8)
            guard try call(.ping, p) == p else { throw Failure("PING 应答不对") }
        }

        /// HMAC(K_unlock, salt) from the card, for the press `pressId` (the one whose
        /// frame matched).  The card answers once per press, within seconds of it.
        public func secret(press pressId: UInt32, salt: Data) throws -> Data {
            precondition(salt.count == 32)
            let r = try call(.secret, withUnsafeBytes(of: pressId.littleEndian, Array.init) + salt)
            guard r.count == 32 else { throw Failure("SECRET 应答长度不对") }
            return Data(r)
        }

        /// The card's signature over (challenge, press, serial): proof that a real press
        /// on this card happened just now.
        public func sign(press pressId: UInt32, challenge: Data) throws -> Data {
            precondition(challenge.count == 32)
            let r = try call(.sign, withUnsafeBytes(of: pressId.littleEndian, Array.init) + challenge)
            guard r.count == 64 else { throw Failure("SIGN 应答长度不对") }
            return Data(r)
        }

        /// The card's half of the key to the fingers file.  Needs no press.
        public func storeSecret(salt: Data) throws -> Data {
            precondition(salt.count == 32)
            let r = try call(.store, Array(salt))
            guard r.count == 32 else { throw Failure("指纹库密钥应答长度不对") }
            return Data(r)
        }

        /// The SSH public key of this pairing, raw X || Y.
        public func sshPublic() throws -> Data {
            let r = try call(.sshPub)
            guard r.count == 64 else { throw Failure("SSH 公钥应答长度不对") }
            return Data(r)
        }

        /// Signature by the pairing's SSH key, raw r || s, spending a press.
        public func sshSign(press pressId: UInt32, digest: Data) throws -> Data {
            precondition(digest.count == 32)
            let r = try call(.sshSign, withUnsafeBytes(of: pressId.littleEndian, Array.init) + digest)
            guard r.count == 64 else { throw Failure("SSH 签名应答长度不对") }
            return Data(r)
        }

        /// Sealed frames of every touch while on; the card stops by itself after 3 s.
        public func setLive(_ on: Bool) throws {
            _ = try call(.live, [on ? 1 : 0])
        }

        /// Both LEDs, r g b of the first and then of the second, before the card's own
        /// brightness cap.  The card hands them back to the firmware 3 s after the last
        /// call or when the session ends.
        public func setLEDs(_ rgb: [UInt8]) throws {
            precondition(rgb.count == 6)
            _ = try call(.led, [1] + rgb)
        }

        public func releaseLEDs() throws {
            _ = try call(.led, [0])
        }

        public func unpair() throws {
            _ = try call(.unpair)
            closed = true
        }

        public func close() {
            _ = try? call(.close, timeout: 1)
            closed = true
        }

        /// The latest sealed frame, decrypted.  nil when there is none, it is not for this
        /// session, or it does not authenticate.
        public func readFrame() throws -> (seq: UInt32, press: UInt32, frame: Data)? {
            guard let (h, cipher) = try mailbox.readSealedImage() else { return nil }
            let ctr = h.u32(24)
            guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(ctr), ciphertext: cipher, tag: h[32..<48]),
                  let plain = try? ChaChaPoly.open(box, using: img, authenticating: h[0..<32])
            else { return nil }
            // Frames only move forward within a session: a replayed old frame is refused.
            guard Int32(bitPattern: ctr &- imgCtr) > 0 else { return nil }
            imgCtr = ctr
            return (h.u32(8), h.u32(16), plain)
        }
    }

    /// The message a SIGN answer covers, as the card hashes it (SHA-256 of this).
    public static func pressMessage(challenge: Data, press: UInt32, serial: Data) -> Data {
        Data("fpcard press v1".utf8) + challenge + withUnsafeBytes(of: press.littleEndian) { Data($0) } + serial
    }

    public static func verifyPress(signature: Data, challenge: Data, press: UInt32, card: Identity) -> Bool {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: card.publicKey),
              let s = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(s, for: SHA256.hash(data: pressMessage(challenge: challenge, press: press,
                                                                              serial: card.serial)))
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for (x, y) in zip(a, b) { d |= x ^ y }
        return d == 0
    }
}
