import CvBridge
import Foundation

/// Tunable parameters, stored in fpdb/settings.json with the same keys as
/// host/fpgui/settings.py so both tools share one file.
public struct ParamSpec {
    public let key: String
    public let label: String
    public let isFloat: Bool
    public let defaultValue: Double
}

public let paramSpecs: [ParamSpec] = [
    // quality
    ParamSpec(key: "block_mean", label: "覆盖判断：块均值下限", isFloat: false, defaultValue: 25),
    ParamSpec(key: "block_std", label: "覆盖判断：块起伏下限", isFloat: false, defaultValue: 10),
    ParamSpec(key: "min_coverage", label: "覆盖比例下限（部分按压）", isFloat: true, defaultValue: 0.6),
    ParamSpec(key: "min_r", label: "对比度 R 下限（不清晰）", isFloat: true, defaultValue: 8.0),
    // features and matching
    ParamSpec(key: "sift_contrast", label: "SIFT 对比度阈值", isFloat: true, defaultValue: 0.02),
    ParamSpec(key: "ratio", label: "比值检验", isFloat: true, defaultValue: 0.8),
    ParamSpec(key: "ransac_px", label: "RANSAC 误差（像素）", isFloat: true, defaultValue: 3.0),
    ParamSpec(key: "max_rot", label: "最大旋转角（度）", isFloat: true, defaultValue: 40.0),
    ParamSpec(key: "match_score", label: "强匹配：内点数", isFloat: false, defaultValue: 8),
    ParamSpec(key: "match_strong_ncc", label: "强匹配：对齐后像素相关下限", isFloat: true, defaultValue: 0.35),
    ParamSpec(key: "match_weak", label: "弱匹配：内点数", isFloat: false, defaultValue: 5),
    ParamSpec(key: "match_ncc", label: "弱匹配：对齐后像素相关下限", isFloat: true, defaultValue: 0.75),
    // enrolment
    ParamSpec(key: "enroll_steps", label: "录入次数", isFloat: false, defaultValue: 32),
    ParamSpec(key: "dup_overlap", label: "重复判断：重叠比例", isFloat: true, defaultValue: 0.9),
    ParamSpec(key: "dup_score", label: "重复判断：内点数", isFloat: false, defaultValue: 40),
    // unlock
    ParamSpec(key: "lockout_fails", label: "连续失败锁定次数", isFloat: false, defaultValue: 5),
    ParamSpec(key: "lockout_secs", label: "锁定秒数", isFloat: false, defaultValue: 30),
    ParamSpec(key: "max_fingers", label: "最多指纹数", isFloat: false, defaultValue: 5),
    ParamSpec(key: "adapt_max", label: "自适应更新：每个指纹最多样本数（0 关闭）", isFloat: false, defaultValue: 80),
]

public final class Settings {
    public let path: URL
    public private(set) var values: [String: Double]

    public init(path: URL) {
        self.path = path
        values = Dictionary(uniqueKeysWithValues: paramSpecs.map { ($0.key, $0.defaultValue) })
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for spec in paramSpecs {
                if let n = obj[spec.key] as? NSNumber {
                    values[spec.key] = n.doubleValue
                }
            }
        }
    }

    public subscript(key: String) -> Double {
        get { values[key] ?? 0 }
        set { values[key] = newValue }
    }

    public func int(_ key: String) -> Int { Int(self[key]) }

    public func save() throws {
        var obj: [String: Any] = [:]
        for spec in paramSpecs {
            let v = self[spec.key]
            obj[spec.key] = spec.isFloat ? v as Any : Int(v) as Any
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path)
    }

    /// The part the OpenCV side needs.
    public var params: FPParams {
        let p = FPParams()
        p.blockMean = self["block_mean"]
        p.blockStd = self["block_std"]
        p.minCoverage = self["min_coverage"]
        p.minR = self["min_r"]
        p.siftContrast = self["sift_contrast"]
        p.ratio = self["ratio"]
        p.ransacPx = self["ransac_px"]
        p.maxRot = self["max_rot"]
        p.matchScore = int("match_score")
        p.matchStrongNcc = self["match_strong_ncc"]
        p.matchWeak = int("match_weak")
        p.matchNcc = self["match_ncc"]
        return p
    }
}
