import CryptoKit
@preconcurrency import FingerCore
import Foundation

/// A Unix socket for this user's own processes, one thread per client.
final class UnixServer: @unchecked Sendable {
    let path: String
    var onClient: ((Int32) -> Void)?
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    func start() {
        guard fd < 0 else { return }
        unlink(path)
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard lfd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            bytes.withUnsafeBytes { buf.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, listen(lfd, 8) == 0 else {
            close(lfd)
            return
        }
        chmod(path, 0o600)
        fd = lfd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { if errno == EINTR { continue } else { return } }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else {
                    close(c)
                    continue
                }
                Thread.detachNewThread { self?.onClient?(c) }
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(path)
    }

    /// The name of the process on the other end, for the prompt.
    static func peerName(_ c: Int32) -> String {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(c, 0 /* SOL_LOCAL */, 2 /* LOCAL_PEERPID */, &pid, &len) == 0, pid > 0 else { return "未知程序" }
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "comm=", "-p", "\(pid)"]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return "未知程序" }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (s.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
    }
}

/// An ssh-agent holding one key, which lives on the card (PROTOCOL.agent).  Each signature
/// takes a press of an enrolled finger.  ssh and git find it through IdentityAgent or
/// SSH_AUTH_SOCK.
final class SSHAgent: @unchecked Sendable {
    struct Request {
        let digest: Data
        let peer: String
        let reply: (Result<Data, Error>) -> Void
    }

    static let keyType = "ecdsa-sha2-nistp256"
    let server: UnixServer
    var onSign: ((Request) -> Void)?
    private let lock = NSLock()
    private var pub: Data?

    var publicKey: Data? {
        get { lock.withLock { pub } }
        set { lock.withLock { pub = newValue } }
    }

    init(directory: URL) {
        server = UnixServer(path: directory.appendingPathComponent("ssh.sock").path)
        server.onClient = { [weak self] c in self?.serve(c) }
    }

    private static func string(_ d: Data) -> Data {
        var n = UInt32(d.count).bigEndian
        return withUnsafeBytes(of: &n) { Data($0) } + d
    }

    private static func mpint(_ d: Data) -> Data {
        var v = d.drop { $0 == 0 }
        if let f = v.first, f & 0x80 != 0 { v.insert(0, at: v.startIndex) }
        return string(Data(v))
    }

    static func blob(_ pub: Data) -> Data {
        string(Data(keyType.utf8)) + string(Data("nistp256".utf8)) + string(Data([4]) + pub)
    }

    static func authorizedKey(_ pub: Data) -> String {
        "\(keyType) \(blob(pub).base64EncodedString()) sd-finger"
    }

    private func readAll(_ c: Int32, _ n: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < n {
            let r = read(c, &buf, min(buf.count, n - out.count))
            if r <= 0 { return nil }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }

    private func send(_ c: Int32, _ payload: Data) {
        let d = SSHAgent.string(payload)
        _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
    }

    private func take(_ d: inout Data) -> Data? {
        guard d.count >= 4 else { return nil }
        let n = d.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard d.count >= 4 + n else { return nil }
        let v = Data(d.dropFirst(4).prefix(n))
        d = Data(d.dropFirst(4 + n))
        return v
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        let failure = Data([5])
        while let h = readAll(c, 4) {
            let n = h.reduce(0) { $0 << 8 | Int($1) }
            guard n > 0, n <= 256 * 1024, let msg = readAll(c, n) else { return }
            var body = Data(msg.dropFirst())
            switch msg[msg.startIndex] {
            case 11: // REQUEST_IDENTITIES
                if let pub = publicKey {
                    send(c, Data([12, 0, 0, 0, 1]) + SSHAgent.string(SSHAgent.blob(pub)) + SSHAgent.string(Data("sd-finger".utf8)))
                } else {
                    send(c, Data([12, 0, 0, 0, 0]))
                }
            case 13: // SIGN_REQUEST
                guard let pub = publicKey, let key = take(&body), key == SSHAgent.blob(pub), let data = take(&body) else {
                    send(c, failure)
                    continue
                }
                let done = DispatchSemaphore(value: 0)
                var result: Result<Data, Error> = .failure(SecureCard.Failure("超时"))
                let req = Request(digest: Data(SHA256.hash(data: data)), peer: UnixServer.peerName(c)) {
                    result = $0
                    done.signal()
                }
                DispatchQueue.main.async { self.onSign?(req) }
                _ = done.wait(timeout: .now() + 40)
                guard case .success(let sig) = result, sig.count == 64 else {
                    send(c, failure)
                    continue
                }
                let inner = SSHAgent.mpint(sig.prefix(32)) + SSHAgent.mpint(sig.suffix(32))
                let blob = SSHAgent.string(Data(SSHAgent.keyType.utf8)) + SSHAgent.string(inner)
                send(c, Data([14]) + SSHAgent.string(blob))
            default:
                send(c, failure)
            }
        }
    }
}

/// `fingerconfirm "原因"`: a script asks for a press before doing something dangerous.
/// A guard against mistakes, not an attacker: a process that can run as the user can also
/// skip the script.  One line of JSON each way.
final class ConfirmBridge: @unchecked Sendable {
    struct Request {
        let reason: String
        let peer: String
        let reply: (Result<Void, Error>) -> Void
    }

    let server: UnixServer
    var onRequest: ((Request) -> Void)?

    init(directory: URL) {
        server = UnixServer(path: directory.appendingPathComponent("confirm.sock").path)
        server.onClient = { [weak self] c in self?.serve(c) }
    }

    private func serve(_ c: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while line.count < 4096, !line.contains(0x0A) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            line.append(contentsOf: buf[0..<n])
        }
        let obj = (try? JSONSerialization.jsonObject(with: line.prefix { $0 != 0x0A })) as? [String: Any]
        let reason = (obj?["reason"] as? String ?? "").prefix(120)
        let req = Request(reason: String(reason), peer: UnixServer.peerName(c)) { r in
            var answer: [String: Any] = ["ok": true]
            if case .failure(let e) = r { answer = ["ok": false, "error": "\(e)"] }
            if var d = try? JSONSerialization.data(withJSONObject: answer) {
                d.append(0x0A)
                _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
            }
            close(c)
        }
        DispatchQueue.main.async { self.onRequest?(req) }
    }
}

/// Lock the screen now.  There is no public call: the login framework's, then the display
/// going to sleep, which locks if the Mac is set to ask for the password at once.
enum ScreenLock {
    static func now() {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let h = dlopen(path, RTLD_LAZY), let f = dlsym(h, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            _ = unsafeBitCast(f, to: Lock.self)()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}
