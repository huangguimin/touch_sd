import Foundation

// fingerconfirm "原因"
//   Exit 0 once an enrolled finger has been pressed on the card, 1 if it was refused,
//   2 if Touch SD is not there.  fingerconfirm "删除生产库" && ./drop_prod.sh

func fail(_ code: Int32, _ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail(2, "用法: fingerconfirm \"要确认的操作\"")
}
let reason = args.dropFirst().joined(separator: " ")
let path = NSHomeDirectory() + "/Library/Application Support/SD Finger/confirm.sock"
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8CString)
guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { fail(2, "路径太长") }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    bytes.withUnsafeBytes { buf.copyMemory(from: $0) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
}
guard connected else { fail(2, "Touch SD 没有运行") }
var request = (try? JSONSerialization.data(withJSONObject: ["reason": reason])) ?? Data()
request.append(0x0A)
_ = request.withUnsafeBytes { write(fd, $0.baseAddress, request.count) }
var tv = timeval(tv_sec: 40, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
FileHandle.standardError.write(Data("请在指纹卡上按一下手指……\n".utf8))
var line = Data()
var buf = [UInt8](repeating: 0, count: 1024)
while !line.contains(0x0A) {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    line.append(contentsOf: buf[0..<n])
}
let obj = (try? JSONSerialization.jsonObject(with: line.prefix { $0 != 0x0A })) as? [String: Any]
if obj?["ok"] as? Bool == true {
    exit(0)
}
fail(1, "没有确认：\(obj?["error"] as? String ?? "超时")")
