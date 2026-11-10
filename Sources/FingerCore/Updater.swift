import CryptoKit
import Foundation

/// INFO.TXT / STATUS.TXT and firmware updates through the card.
public enum CardFiles {
    /// Read past the page cache: the firmware rewrites these files in place.
    public static func readNoCache(_ path: String, max: Int = 4096) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, CardMailbox.F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let size = min(max, Int(st.st_size))
        guard size > 0, let buf = try? CardMailbox.readSectors(fd, size, offset: 0) else { return nil }
        return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// INFO.TXT as ordered key/value pairs.
    public static func info(volume: String) -> [(String, String)] {
        guard let text = readNoCache(volume + "/INFO.TXT") else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }
    }

    public static func status(volume: String) -> String {
        readNoCache(volume + "/STATUS.TXT") ?? ""
    }
}

public struct Version: Comparable, CustomStringConvertible {
    public let major, minor: Int
    public init?(_ s: String) {
        let p = s.split(separator: ".").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        major = p[0]
        minor = p[1]
    }
    init(packed: UInt32) {
        major = Int(packed >> 16)
        minor = Int(packed & 0xFFFF)
    }
    public static func < (a: Version, b: Version) -> Bool { (a.major, a.minor) < (b.major, b.minor) }
    public var description: String { "\(major).\(minor)" }
}

/// UPDATE.BIN: a 256-byte header and the image, as the manufacturer publishes it.
public struct UpdatePackage {
    public let data: Data
    public let image: Version
    public let firmware: Version
    public let imageSize: Int

    public struct Bad: Error, CustomStringConvertible {
        public let description: String
    }

    public init(url: URL) throws {
        data = try Data(contentsOf: url)
        let b = [UInt8](data)
        guard b.count >= 256, Array(b[0..<8]) == Array("SDTUPD01".utf8) else {
            throw Bad(description: "不是 SD_TOUCH 的 UPDATE.BIN")
        }
        // flags: 0 development image, 3 signed and encrypted (the card takes only its own kind)
        guard b.u32(8) == 256, b.u32(20) == 0 || b.u32(20) == 3 else {
            throw Bad(description: "头长度或标志不对")
        }
        imageSize = Int(b.u32(12))
        guard b.count - 256 == imageSize, imageSize > 0, imageSize <= 512 * 1024 else {
            throw Bad(description: "镜像长度和头里写的不符")
        }
        guard Array(SHA256.hash(data: data.subdata(in: 256..<data.count))) == Array(b[32..<64]) else {
            throw Bad(description: "SHA-256 不符，文件可能损坏")
        }
        image = Version(packed: b.u32(16))
        firmware = Version(packed: b.u32(24))
    }
}

/// Copy UPDATE.BIN to the card, let it flash itself and come back without re-inserting:
/// unmount (the host then leaves the card alone), wait while it writes flash and reboots
/// into the new image, which picks the old SD session up, then mount it again.
public enum Updater {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    static let chunk = 4096
    static let fsyncEvery = 16 * 1024
    static let spare = 8 * 512

    /// Blocking; call off the main thread.  log gets progress lines.  Returns the new
    /// STATUS.TXT head.  The card must not be open elsewhere (disconnect first).
    public static func run(_ pkg: UpdatePackage, volume: String, force: Bool = false,
                           log: (String) -> Void) throws -> String {
        let fw = CardFiles.info(volume: volume).first { $0.0 == "fw" }.flatMap { Version($0.1) }
        log("卡上 \(fw?.description ?? "未知") -> 固件 \(pkg.firmware)（镜像 \(pkg.image)）")
        if !force, let fw, pkg.firmware <= fw {
            throw Failure(description: "版本号必须递增：卡上已经是 \(fw)，要装的是 \(pkg.firmware)")
        }
        var st = statfs()
        guard statfs(volume, &st) == 0 else { throw Failure(description: "读不到卡的剩余空间") }
        let free = Int(st.f_bavail) * Int(st.f_bsize)
        guard pkg.data.count + spare <= free else {
            throw Failure(description: "卡上只剩 \(free) 字节，放不下 \(pkg.data.count) 字节的更新包")
        }

        let dest = volume + "/UPDATE.BIN"
        log("拷贝 \(pkg.data.count) 字节到 \(dest)")
        let fd = open(dest, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Failure(description: "写不了 \(dest)") }
        var written = 0, sinceSync = 0
        let bytes = [UInt8](pkg.data)
        while written < bytes.count {
            let n = min(chunk, bytes.count - written)
            let w = bytes[written..<written + n].withUnsafeBytes { write(fd, $0.baseAddress, n) }
            guard w == n else {
                close(fd)
                throw Failure(description: "写卡失败：\(String(cString: strerror(errno)))")
            }
            written += n
            sinceSync += n
            if sinceSync >= fsyncEvery {
                fsync(fd)
                sinceSync = 0
            }
        }
        fsync(fd)
        close(fd)
        // Spot-check past the cache: a card that refused the data still looks fine through it.
        let rfd = open(dest, O_RDONLY)
        _ = fcntl(rfd, CardMailbox.F_NOCACHE, 1)
        for off in [0, (bytes.count / 2) & ~511, max(0, bytes.count - 4096) & ~511] {
            let n = min(4096, bytes.count - off)
            let got = try? CardMailbox.readSectors(rfd, n, offset: off)
            if got == nil || got! != Array(bytes[off..<off + n]) {
                close(rfd)
                throw Failure(description: "读回不一致（偏移 \(off)）：卡没有收下这个文件")
            }
        }
        close(rfd)

        guard let dev = shell("/usr/sbin/diskutil", ["info", volume]).firstMatch(#"Device Identifier:\s+(\S+)"#) else {
            throw Failure(description: "拿不到卷的设备号，请拔插卡后看 STATUS.TXT")
        }
        _ = shell("/usr/sbin/diskutil", ["unmount", volume])
        log("已卸载 \(dev)，等 12 秒让卡写闪存、重启……")
        Thread.sleep(forTimeInterval: 12)
        var mounted = false
        for _ in 0..<3 {
            if shellStatus("/usr/sbin/diskutil", ["mount", dev]) == 0 {
                mounted = true
                break
            }
            Thread.sleep(forTimeInterval: 3)
        }
        guard mounted else {
            throw Failure(description: "重新挂载失败：卡没能接回原来的会话（或旧固件不支持），请把卡拔出再插入")
        }
        Thread.sleep(forTimeInterval: 1)
        let status = CardFiles.status(volume: volume)
        let head = status.split(separator: "\n").filter {
            $0.hasPrefix("sd_touch") || $0.hasPrefix("boot:") || $0.hasPrefix("ota:")
        }.joined(separator: "\n")
        guard status.contains("image \(pkg.image) ") else {
            throw Failure(description: "还在跑旧固件（期望镜像 \(pkg.image)）：\n" + head)
        }
        log("升级完成，没有拔插卡")
        return head
    }

    @discardableResult
    static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func shellStatus(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

extension String {
    /// First capture group of a regular expression.
    public func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
