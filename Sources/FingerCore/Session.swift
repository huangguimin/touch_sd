import CvBridge
import Foundation

// Phone-like enrolment and unlock (host/fpgui/session.py).
//
// Enrolment follows Android's FingerprintEnrollEnrolling: progress = successful presses /
// total; a side sensor goes through 4 stages at 25 / 50 / 75 %: centre -> tip -> left edge
// -> right edge.  A poor capture gets a help message and does not count; one that nearly
// repeats an earlier sample asks to move the finger.  Unlock locks out for 30 s after 5
// failures in a row; an accepted press that is not a near-duplicate joins the template
// (adaptive update), which fills in coverage on a narrow sensor over time.  Every good
// frame of a press is tried, any pass counts.

public let helpText: [String: String] = [
    QualityCode.partial.rawValue: "检测到部分指纹，请用手指盖满传感器",
    QualityCode.insufficient.rawValue: "无法处理指纹，请重试",
    QualityCode.tooFast.rawValue: "手指移动太快，请按住稍久一点",
    "duplicate": "请每次稍微挪动一下手指位置",
]

public struct Stage {
    public let name, title, description: String
}

public let stages = [
    Stage(name: "中心", title: "将指腹中间放在传感器上", description: "每次抬起手指后，稍微挪动一下位置再按"),
    Stage(name: "指尖", title: "用指尖按压传感器", description: "调整手指角度，让指尖部分也被记录下来"),
    Stage(name: "左侧", title: "用手指左侧边缘按压", description: "把手指向右倾斜，用左侧边缘接触传感器"),
    Stage(name: "右侧", title: "用手指右侧边缘按压", description: "把手指向左倾斜，用右侧边缘接触传感器"),
]
public let stageThresholds = [0.25, 0.5, 0.75]

public func stageIndex(progress: Double) -> Int {
    stageThresholds.filter { progress >= $0 }.count
}

public enum ResultKind {
    case help, progress, done, match, nomatch, locked
}

public struct SessionResult {
    public var kind: ResultKind
    public var message: String
    public var quality: Quality?
    public var code: String?
    public var sample: FPSample?      // enrolment: the new sample; unlock: the probe used
    public var match: FPMatch?
    public var index: Int = -1        // best template index
    public var finger: Finger?
    public var learn = false
    public var learnSample: FPSample?
}

func assess(_ raw: Data?, _ p: FPParams) -> (Quality?, QualityCode) {
    guard let raw else { return (nil, .tooFast) }
    let q = Quality(raw, p)
    return (q, q.code)
}

public final class EnrollSession {
    private let settings: Settings
    private let p: FPParams
    public let steps: Int
    public private(set) var samples: [FPSample] = []

    public init(settings: Settings) {
        self.settings = settings
        p = settings.params
        steps = settings.int("enroll_steps")
    }

    public var done: Int { samples.count }
    public var progress: Double { Double(done) / Double(steps) }
    public var stage: (Int, Stage) {
        let k = stageIndex(progress: progress)
        return (k, stages[k])
    }

    public func onTouch(_ raw: Data?) -> SessionResult {
        let (q, code) = assess(raw, p)
        guard code == .good, let raw else {
            return SessionResult(kind: .help, message: helpText[code.rawValue]!, quality: q, code: code.rawValue)
        }
        let s = FPSample(raw: raw, params: p)
        var idx = -1
        let m = FPMatcher.best(s, in: samples, params: p, index: &idx)
        if Double(m.score) >= settings["dup_score"] && m.overlap >= settings["dup_overlap"] {
            return SessionResult(kind: .help, message: helpText["duplicate"]!, quality: q, code: "duplicate",
                                 sample: s, match: m, index: idx)
        }
        samples.append(s)
        if done >= steps {
            return SessionResult(kind: .done, message: "已添加指纹", quality: q, sample: s, match: m, index: idx)
        }
        return SessionResult(kind: .progress, message: "抬起手指，然后再次按压", quality: q, sample: s,
                             match: m, index: idx)
    }
}

public final class VerifySession {
    private let settings: Settings
    public private(set) var fails = 0
    private var lockedUntil = Date.distantPast

    public init(settings: Settings) {
        self.settings = settings
    }

    public var lockedLeft: TimeInterval { max(0, lockedUntil.timeIntervalSinceNow) }

    public func reset() {
        fails = 0
        lockedUntil = .distantPast
    }

    /// raws: the press's frames, best contrast first; the first decides the quality hint.
    public func onTouch(_ raws: [Data], fingers: [Finger]) -> SessionResult {
        let p = settings.params
        let left = lockedLeft
        if left > 0 {
            return SessionResult(kind: .locked, message: "尝试次数过多，请 \(Int(left + 0.99)) 秒后重试")
        }
        let (q, code) = assess(raws.first, p)
        guard code == .good, let first = raws.first else {
            // a poor capture is not a failed attempt, as on a phone
            return SessionResult(kind: .help, message: helpText[code.rawValue]!, quality: q, code: code.rawValue)
        }
        let probes = [FPSample(raw: first, params: p)] +
            raws.dropFirst().filter { assess($0, p).1 == .good }.map { FPSample(raw: $0, params: p) }
        var best: FPMatch?
        var who: Finger?
        var idx = -1
        var probe = probes[0]
        outer: for pr in probes {
            for g in fingers {
                var i = -1
                let m = FPMatcher.best(pr, in: g.samples, params: p, index: &i)
                if best == nil || m.isStronger(than: best!) {
                    best = m
                    who = g
                    idx = i
                    probe = pr
                }
            }
            if let best, best.accepted { break outer }
        }
        if let best, best.accepted, let who {
            fails = 0
            let learn = Double(who.samples.count) < settings["adapt_max"] &&
                !(Double(best.score) >= settings["dup_score"] && best.overlap >= settings["dup_overlap"])
            // the adaptive update keeps the highest-contrast frame (as eval_dataset.py --adapt)
            return SessionResult(kind: .match, message: "已解锁：\(who.name)", quality: q, sample: probe,
                                 match: best, index: idx, finger: who, learn: learn, learnSample: probes[0])
        }
        fails += 1
        if fails >= settings.int("lockout_fails") {
            lockedUntil = Date().addingTimeInterval(settings["lockout_secs"])
            fails = 0
            return SessionResult(kind: .locked, message: "尝试次数过多，请 \(settings.int("lockout_secs")) 秒后重试",
                                 quality: q, sample: probe, match: best, index: idx, finger: who)
        }
        return SessionResult(kind: .nomatch, message: "指纹无法识别（\(fails)/\(settings.int("lockout_fails"))）",
                             quality: q, sample: probe, match: best, index: idx, finger: who)
    }
}
