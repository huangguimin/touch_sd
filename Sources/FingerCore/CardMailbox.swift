import Foundation

/// The card's fixed-sector mailbox (docs/CARD_PROTOCOL.md).  Only whole sectors of files the firmware created are read or
/// overwritten in place, so no FAT or directory traffic is involved.
public final class CardMailbox {
    /// Firmware 0.60 on mounts as TOUCH_SD; older cards still mount as SD_TOUCH.
    public static let volumes = ["/Volumes/TOUCH_SD", "/Volumes/SD_TOUCH"]
    public static var volume: String {
        volumes.first { FileManager.default.fileExists(atPath: $0) } ?? volumes[0]
    }
    static let sector = 512
    static let imageSectors = (FrameImage.frameBytes + sector - 1) / sector
    static let F_NOCACHE: Int32 = 48
    static let F_FULLFSYNC: Int32 = 51

    public enum Kind: UInt8 {
        case ping = 0x01, status = 0x02
    }
    static let reply: UInt8 = 0x80
    static let error: UInt8 = 0xFF
    public static let payloadMax = 488

    public struct ImageHeader {
        public let seq: UInt32
        public let length: Int
        public let crc: UInt32
        public let mean, ridge: Double
        public let uptimeMs: UInt32
    }

    public struct SlideState {
        public let seq: UInt32
        public let touching: Bool
        public let touchId: UInt32
        public let pos: Int32
        public let delta: Int16
        public let lo, hi: Int
        public let method: Int
        public let frames: UInt32
        public let imageSeq: UInt32?   // latest frame in FPIMG.BIN (firmware 0.11 on)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public let path: String
    private let img, slide, out: Int32
    private let input: [Int32]
    private var slot = 0
    private var seq = UInt32.random(in: 0..<0x7FFF_FFFF)  // fresh per session (see protocol)

    public init(volume: String = CardMailbox.volume) throws {
        path = volume
        func open(_ name: String, _ flags: Int32) throws -> Int32 {
            let fd = Darwin.open(volume + "/" + name, flags)
            guard fd >= 0 else { throw Failure(description: "打不开 \(name)：\(String(cString: strerror(errno)))") }
            _ = fcntl(fd, CardMailbox.F_NOCACHE, 1)
            return fd
        }
        img = try open("FPIMG.BIN", O_RDONLY)
        slide = try open("FPTOUCH.BIN", O_RDONLY)
        out = try open("HOSTOUT.BIN", O_RDONLY)
        input = [try open("HOSTIN0.BIN", O_RDWR), try open("HOSTIN1.BIN", O_RDWR)]
    }

    deinit {
        for fd in [img, slide, out] + input {
            Darwin.close(fd)
        }
    }

    /// One read.  What reaches the card is not what is asked for here: macOS reads a whole
    /// page's worth, clipped to the end of the file, even with F_NOCACHE.  So in a
    /// one-sector file (FPTOUCH, HOSTOUT) this is a CMD17 of ~0.4 ms, but any read of
    /// FPIMG.BIN, even 512 bytes, is a 13-block CMD18 of ~10 ms (seen on a logic analyser,
    /// 2026-10-30).  Poll one-sector files only, and read a multi-sector file once.
    static func readSectors(_ fd: Int32, _ length: Int, offset: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: length)
        let n = pread(fd, &buf, length, off_t(offset))
        guard n == length else {
            throw Failure(description: "读卡失败：\(n < 0 ? String(cString: strerror(errno)) : "数据不全")")
        }
        return buf
    }

    private func readSector(_ fd: Int32, _ length: Int = sector, offset: Int = 0) throws -> [UInt8] {
        try CardMailbox.readSectors(fd, length, offset: offset)
    }

    // MARK: card -> host: frames

    /// The plaintext frame of a development image: (header, frame); nil if there is none, the
    /// card was mid-write or the CRC does not match.  The whole file in one read (one CMD18).
    public func readImage() throws -> (ImageHeader, Data)? {
        let all = try readSector(img, (1 + CardMailbox.imageSectors) * CardMailbox.sector)
        guard all.u32(0) == 0x4954_4453, all[4] == 1, Int(all.u32(12)) == FrameImage.frameBytes else { return nil }  // "SDTI"
        let start = CardMailbox.sector
        let frame = Array(all[start..<start + FrameImage.frameBytes])
        guard CRC32.of(frame) == all.u32(16) else { return nil }
        let h = ImageHeader(seq: all.u32(8), length: Int(all.u32(12)), crc: all.u32(16),
                            mean: Double(all.u16(20)) / 10, ridge: Double(all.u16(22)) / 10, uptimeMs: all.u32(24))
        return (h, Data(frame))
    }

    /// A frame sealed for the open session ("SDTE"): the 48-byte header (32 bytes of
    /// associated data, then the tag) and the ciphertext.  nil if there is none or the
    /// card was mid-write.
    public func readSealedImage() throws -> (header: [UInt8], cipher: [UInt8])? {
        // the whole file in one read (one CMD18); the tag catches a frame replaced midway
        let all = try readSector(img, (1 + CardMailbox.imageSectors) * CardMailbox.sector)
        guard all.u32(0) == 0x4554_4453, all[4] == 2, Int(all.u32(12)) == FrameImage.frameBytes else { return nil }
        let start = CardMailbox.sector
        return (Array(all.prefix(48)), Array(all[start..<start + FrameImage.frameBytes]))
    }

    // MARK: card -> host: slide

    public func slideState() throws -> SlideState? {
        let b = try readSector(slide)
        guard CRC32.of(Array(b[0..<32])) == b.u32(32), b.u32(0) == 0x5354_4453, b[4] == 1 else { return nil }  // "SDTS"
        return SlideState(seq: b.u32(8), touching: b[5] != 0, touchId: b.u32(12), pos: Int32(bitPattern: b.u32(16)),
                          delta: Int16(bitPattern: b.u16(20)), lo: Int(b[22]), hi: Int(b[23]),
                          method: Int(b[6]), frames: b.u32(24),
                          imageSeq: CRC32.of(Array(b[36..<40])) == b.u32(40) ? b.u32(36) : nil)
    }

    // MARK: host -> card: request / reply

    public func request(_ kind: Kind, _ payload: [UInt8] = [], timeout: TimeInterval = 2) throws -> (UInt8, [UInt8]) {
        let r = try request(type: kind.rawValue, payload: payload, timeout: timeout)
        return (r.type, r.body)
    }

    /// Bytes 0..7 of a packet header: the associated data of a sealed packet.
    public static func headerAAD(type: UInt8, flags: UInt16) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 8)
        h.put32(0, 0x4D54_4453)  // "SDTM"
        h[4] = 1
        h[5] = type
        h.put16(6, flags)
        return h
    }

    /// One request/reply.  An error reply (type 0xFF) throws with the card's reason.
    public func request(type: UInt8, flags: UInt16 = 0, payload: [UInt8],
                        timeout: TimeInterval = 2) throws -> (type: UInt8, flags: UInt16, body: [UInt8]) {
        precondition(payload.count <= CardMailbox.payloadMax)
        seq &+= 1
        var pkt = [UInt8](repeating: 0, count: CardMailbox.sector)
        pkt.replaceSubrange(0..<8, with: CardMailbox.headerAAD(type: type, flags: flags))
        pkt.put32(8, seq)
        pkt.put16(16, UInt16(payload.count))
        pkt.replaceSubrange(24..<24 + payload.count, with: payload)
        pkt.put32(20, CRC32.of(payload, initial: CRC32.of(Array(pkt[0..<20]))))
        let fd = input[slot]
        slot ^= 1
        guard pwrite(fd, pkt, pkt.count, 0) == pkt.count else {
            throw Failure(description: "写卡失败：\(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, CardMailbox.F_FULLFSYNC)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let p = try readSector(out)
            let len = Int(p.u16(16))
            if p.u32(0) == 0x4D54_4453, p[4] == 1, len <= CardMailbox.payloadMax,
               CRC32.of(Array(p[24..<24 + len]), initial: CRC32.of(Array(p[0..<20]))) == p.u32(20),
               p.u32(12) == seq {
                let body = Array(p[24..<24 + len])
                if p[5] == CardMailbox.error {
                    throw Failure(description: String(decoding: body, as: UTF8.self))
                }
                return (p[5], p.u16(6), body)
            }
            usleep(20_000)
        }
        throw Failure(description: String(format: "卡在 %.1f 秒内没有应答", timeout))
    }

    public func ping() throws -> TimeInterval {
        let t0 = Date()
        let payload = Array("ping".utf8)
        let (kind, body) = try request(.ping, payload)
        guard kind == Kind.ping.rawValue | CardMailbox.reply, body == payload else {
            throw Failure(description: "PING 应答不对")
        }
        return Date().timeIntervalSince(t0)
    }

    public func statusText() throws -> String {
        String(decoding: try request(.status).1, as: UTF8.self)
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    /// Same as zlib.crc32(data, initial).
    public static func of(_ data: [UInt8], initial: UInt32 = 0) -> UInt32 {
        var c = ~initial
        for b in data {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return ~c
    }
}

extension Array where Element == UInt8 {
    func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    mutating func put16(_ o: Int, _ v: UInt16) {
        self[o] = UInt8(v & 0xFF)
        self[o + 1] = UInt8(v >> 8)
    }
    mutating func put32(_ o: Int, _ v: UInt32) {
        put16(o, UInt16(v & 0xFFFF))
        put16(o + 2, UInt16(v >> 16))
    }
}
