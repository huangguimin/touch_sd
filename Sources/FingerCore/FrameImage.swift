import CvBridge
import Foundation

/// Sensor frame layout (host/fpgui/image.py): 1 dummy byte, then 160 rows x 36 bytes.  The
/// usable image is rows 8-159 (the first 8 are ADC settling) and columns 0-34 (the last is
/// always zero): 152 x 35, rows along the sensor's long side.
public enum FrameImage {
    public static let frameBytes = 36 * 160 + 1
    public static let rows = 152
    public static let cols = 35

    /// 5761-byte frame -> 152 x 35 raw image.
    public static func raw(fromFrame frame: Data) -> Data {
        precondition(frame.count == frameBytes)
        var out = Data(count: rows * cols)
        frame.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for r in 0..<rows {
                    for c in 0..<cols {
                        dst[r * cols + c] = src[1 + (r + 8) * 36 + c]
                    }
                }
            }
        }
        return out
    }

    public static func contrast(_ raw: Data) -> Double { FPQuality.contrast(raw) }

    /// best_frame: the frame of a press with the most ridge contrast (first one on a tie).
    public static func bestRaw(_ frames: [Data]) -> Data? {
        var best: (Data, Double)?
        for f in frames {
            let r = raw(fromFrame: f)
            let c = contrast(r)
            if best == nil || c > best!.1 {
                best = (r, c)
            }
        }
        return best?.0
    }

    /// The press's frames, best contrast first (what unlock tries, in order).
    public static func rawsByContrast(_ frames: [Data]) -> [Data] {
        frames.map { raw(fromFrame: $0) }
            .map { ($0, contrast($0)) }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map { $0.element.0 }
    }

    /// landscape: transpose so the long side is horizontal (35 rows x 152 columns).
    public static func landscape(_ raw: Data) -> Data {
        var out = Data(count: rows * cols)
        raw.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for r in 0..<rows {
                    for c in 0..<cols {
                        dst[c * rows + r] = src[r * cols + c]
                    }
                }
            }
        }
        return out
    }

    /// stretch: map the 1st..99th percentile onto 0..255 (numpy's linear percentile).
    public static func stretch(_ img: Data) -> Data {
        let sorted = img.map { Double($0) }.sorted()
        func pct(_ q: Double) -> Double {
            let pos = q / 100 * Double(sorted.count - 1)
            let i = Int(pos.rounded(.down))
            let f = pos - Double(i)
            return i + 1 < sorted.count ? sorted[i] + (sorted[i + 1] - sorted[i]) * f : sorted[i]
        }
        let lo = pct(1)
        let hi = max(pct(99), lo + 1)
        return Data(img.map { v in
            UInt8(max(0, min(255, (Double(v) - lo) * 255 / (hi - lo))))
        })
    }
}

/// image.Quality, with the codes the sessions use.
public enum QualityCode: String {
    case good, partial, insufficient, tooFast = "too_fast"

    public var text: String {
        switch self {
        case .good: return "合格"
        case .partial: return "部分按压"
        case .insufficient: return "不清晰"
        case .tooFast: return "按得太快"
        }
    }
}

public struct Quality: CustomStringConvertible {
    public let mean, r, coverage: Double
    public let code: QualityCode

    public init(_ raw: Data, _ p: FPParams) {
        let q = FPQuality.measure(raw, params: p)
        mean = q.mean
        r = q.r
        coverage = q.coverage
        switch q.code {
        case .good: code = .good
        case .partial: code = .partial
        default: code = .insufficient
        }
    }

    public var description: String {
        String(format: "mean=%.0f R=%.1f 覆盖=%.0f%%", mean, r, coverage * 100)
    }
}
