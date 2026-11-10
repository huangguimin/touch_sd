import AppKit
@preconcurrency import FingerCore
import Foundation

/// sudo with the card (pam/pam_sdfinger.c).  The PAM module, running as root inside sudo,
/// connects to this socket with a fresh random challenge; the app waits for a matching
/// press and asks the card to sign (challenge, press, serial).  The module checks that
/// signature against the card key installed for the user in /etc/sdfinger (root-owned),
/// so neither a fake app on the socket nor a replayed answer gets through without the
/// paired card and a real press.  The finger match itself happens here, in the app; see
/// docs/SECURITY_DESIGN.md section 10 for what that does and does not protect against.
///
/// Line protocol, one exchange per connection:
///   module -> app  {"v":1,"challenge":"<64 hex>","user":"…","service":"sudo"}
///   app -> module  {"ok":true,"press":N,"sig":"<128 hex>"}  or  {"ok":false,"error":"…"}
final class SudoBridge: @unchecked Sendable {
    struct Request {
        let challenge: Data
        let user: String
        let reply: (Result<(UInt32, Data), Error>) -> Void
    }

    let path: String
    var onRequest: ((Request) -> Void)?
    private var fd: Int32 = -1

    static let modulePath = "/usr/local/lib/pam/pam_sdfinger.so.2"
    static let keyDir = "/etc/sdfinger"
    static let pamFile = "/etc/pam.d/sudo_local"
    static let pamLine = "auth       sufficient     /usr/local/lib/pam/pam_sdfinger.so.2"

    init(directory: URL) {
        path = directory.appendingPathComponent("sudo.sock").path
    }

    func start() {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            bytes.withUnsafeBytes { buf.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, listen(fd, 4) == 0 else {
            close(fd)
            fd = -1
            return
        }
        chmod(path, 0o600)
        let lfd = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { if errno == EINTR { continue } else { return } }
                self?.serve(c)
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func serve(_ c: Int32) {
        // Only sudo's PAM module (root) may ask: an ordinary process using the app as a
        // signing service would still need the press, but it has no business here.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == 0 else {
            close(c)
            return
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        var line = Data()
        while line.count < 1024, !line.contains(0x0A) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            line.append(contentsOf: buf[0..<n])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: line.prefix { $0 != 0x0A }) as? [String: Any],
              let ch = (obj["challenge"] as? String).flatMap({ Data(hex: $0) }), ch.count == 32 else {
            respond(c, ["ok": false, "error": "bad request"])
            return
        }
        let user = obj["user"] as? String ?? ""
        let req = Request(challenge: ch, user: user) { [weak self] r in
            switch r {
            case .success(let (press, sig)):
                self?.respond(c, ["ok": true, "press": Int(press), "sig": sig.hexString])
            case .failure(let e):
                self?.respond(c, ["ok": false, "error": "\(e)"])
            }
        }
        DispatchQueue.main.async { self.onRequest?(req) }
    }

    private func respond(_ c: Int32, _ obj: [String: Any]) {
        if var d = try? JSONSerialization.data(withJSONObject: obj) {
            d.append(0x0A)
            _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
        }
        close(c)
    }

    // MARK: install / uninstall (administrator password via AppleScript)

    static var installed: Bool {
        FileManager.default.fileExists(atPath: modulePath) &&
            ((try? String(contentsOfFile: pamFile, encoding: .utf8))?.contains("pam_sdfinger.so") ?? false)
    }

    static var installedKey: String? {
        try? String(contentsOfFile: "\(keyDir)/\(NSUserName()).pub", encoding: .utf8)
    }

    static func keyFile(_ card: PairedCard) -> String {
        "pub=\(card.publicKey.hexString)\nserial=\(card.serial.hexString)\n"
    }

    /// Copy the module, write the user's card key and add the sudo_local line.  The
    /// module is checked to load before sudo is pointed at it.
    static func install(card: PairedCard, module: URL) throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw SecureCard.Failure("用户名含特殊字符，不支持自动安装")
        }
        // A module sudo cannot load would break the whole sudo_local chain.
        guard let h = dlopen(module.path, RTLD_NOW), dlsym(h, "pam_sm_authenticate") != nil else {
            throw SecureCard.Failure("模块加载失败：\(String(cString: dlerror()))")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sdfinger-\(UUID().uuidString).pub")
        try keyFile(card).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = """
        set -e
        mkdir -p /usr/local/lib/pam \(keyDir)
        install -o root -g wheel -m 444 '\(module.path)' '\(modulePath)'
        install -o root -g wheel -m 444 '\(tmp.path)' '\(keyDir)/\(user).pub'
        touch \(pamFile)
        if ! grep -q pam_sdfinger.so \(pamFile); then
          { echo '# SD Finger: sudo with the fingerprint card (remove this line to turn it off)'; echo '\(pamLine)'; cat \(pamFile); } > \(pamFile).sdfinger
          install -o root -g wheel -m 444 \(pamFile).sdfinger \(pamFile)
          rm -f \(pamFile).sdfinger
        fi
        """
        try runAsAdmin(script, prompt: "Touch SD 要安装 sudo 指纹模块。")
    }

    static func uninstall() throws {
        let user = NSUserName()
        let script = """
        if [ -f \(pamFile) ]; then
          grep -v -e 'pam_sdfinger.so' -e '^# SD Finger: sudo' \(pamFile) > \(pamFile).sdfinger || true
          install -o root -g wheel -m 444 \(pamFile).sdfinger \(pamFile)
          rm -f \(pamFile).sdfinger
        fi
        rm -f '\(modulePath)' '\(keyDir)/\(user).pub'
        """
        try runAsAdmin(script, prompt: "Touch SD 要移除 sudo 指纹模块。")
    }

    private static func runAsAdmin(_ script: String, prompt: String) throws {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src) else { throw SecureCard.Failure("脚本出错") }
        s.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "\(err)"
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { throw SecureCard.Failure("已取消") }
            throw SecureCard.Failure(msg)
        }
    }
}
