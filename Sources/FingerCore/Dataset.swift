import CvBridge
import Foundation

/// Labelled presses for offline evaluation (host/fpgui/dataset.py, same files):
/// <root>/<finger label>/<time>_<n>.txt, each holding every frame of one press as
/// FRAME / IMG_BEGIN / hex / IMG_END, plus <root>/index.csv with one row per press.
public enum Dataset {
    public static let fields = ["time", "label", "file", "frames", "code", "mean", "r", "coverage"]

    public static func safe(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = trimmed.replacingOccurrences(of: #"[\\/:*?"<>|\s]+"#, with: "_",
                                               options: .regularExpression)
        return out.isEmpty ? "unlabeled" : out
    }

    /// Frames of a press file (also reads captures/touch/*.txt).
    public static func loadFrames(_ url: URL) -> [Data] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Data] = []
        for part in text.components(separatedBy: "IMG_BEGIN").dropFirst() {
            let body = part.components(separatedBy: "IMG_END")[0]
            let hex = body.filter { $0.isHexDigit && !$0.isUppercase }
            if let data = Data(hex: hex), data.count == FrameImage.frameBytes {
                out.append(data)
            }
        }
        return out
    }

    /// {label directory: presses}
    public static func counts(_ root: URL) -> [(String, Int)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return dirs.sorted().compactMap { d in
            var isDir: ObjCBool = false
            let p = root.appendingPathComponent(d)
            guard fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let n = (try? fm.contentsOfDirectory(atPath: p.path))?.filter { $0.hasSuffix(".txt") }.count ?? 0
            return (d, n)
        }
    }

    public struct Press {
        public let label: String
        public let url: URL
        public let bestRaw: Data
    }

    /// Every press with frames, in file-name (= capture) order per label.
    public static func load(_ root: URL) -> [Press] {
        var out: [Press] = []
        for (label, _) in counts(root) {
            let d = root.appendingPathComponent(label)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
                .filter { $0.hasSuffix(".txt") }.sorted()
            for f in files {
                let url = d.appendingPathComponent(f)
                if let best = FrameImage.bestRaw(loadFrames(url)) {
                    out.append(Press(label: label, url: url, bestRaw: best))
                }
            }
        }
        return out
    }

    /// Save one press; returns (path relative to root, quality of the best frame).
    @discardableResult
    public static func saveTouch(label: String, frames: [(index: Int, mean: Double, data: Data)],
                                 params p: FPParams, root: URL) throws -> (String, Quality?) {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(safe(label))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".txt") }.count + 1
        let name = String(format: "%@_%03d.txt", Stamp.compact(), n)
        let q = FrameImage.bestRaw(frames.map { $0.data }).map { Quality($0, p) }
        let code = q?.code ?? .tooFast
        var text = "# label=\(label) code=\(code.rawValue) frames=\(frames.count)\n"
        for f in frames {
            text += String(format: "FRAME 0 %d mean=%.1f\nIMG_BEGIN\n", f.index, f.mean)
            text += f.data.hexString + "\nIMG_END\n"
        }
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let idx = root.appendingPathComponent("index.csv")
        var row = ""
        if !fm.fileExists(atPath: idx.path) {
            row += fields.joined(separator: ",") + "\r\n"
        }
        let rel = safe(label) + "/" + name
        let cells = [Stamp.human(), label, rel, String(frames.count), code.rawValue,
                     q.map { String(format: "%.1f", $0.mean) } ?? "",
                     q.map { String(format: "%.1f", $0.r) } ?? "",
                     q.map { String(format: "%.2f", $0.coverage) } ?? ""]
        row += cells.map(csvCell).joined(separator: ",") + "\r\n"
        if let h = FileHandle(forWritingAtPath: idx.path) {
            h.seekToEndOfFile()
            h.write(row.data(using: .utf8)!)
            h.closeFile()
        } else {
            try row.write(to: idx, atomically: true, encoding: .utf8)
        }
        return (rel, q)
    }

    private static func csvCell(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

public enum Stamp {
    /// 20261028-191500
    public static func compact(_ d: Date = Date()) -> String { format(d, "yyyyMMdd-HHmmss") }
    /// 2026-10-28 19:15:00
    public static func human(_ d: Date = Date()) -> String { format(d, "yyyy-MM-dd HH:mm:ss") }

    private static func format(_ d: Date, _ f: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = f
        return df.string(from: d)
    }
}

extension Data {
    public init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var it = hex.utf8.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let hi = Data.nibble(a), let lo = Data.nibble(b) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    public var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
