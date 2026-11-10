@preconcurrency import FingerCore
import SwiftUI

/// Finger slides -> a volume-style value.  The card computes the
/// movement (docs/CARD_PROTOCOL.md, FPTOUCH.BIN); this side turns the change in the accumulated
/// position between two readings into a change of the value, so a missed reading loses no
/// distance.  Optionally drives the Mac's output volume.
@MainActor
public final class SlideModel: ObservableObject {
    public static let rows = 152
    public static let traceSeconds = 6.0

    @Published public var volume = 50.0
    @Published public var touching = false
    @Published public var span: (Int, Int)?
    @Published public var trace: [(Date, Int32)] = []
    @Published public var info = "未连接卡，或还没有滑动数据"
    @Published public var rowsPerPercent = 8.0
    @Published public var invert = false
    /// The product app turns this on by default, the development tool does not.
    @Published public var driveSystem = UserDefaults.standard.bool(forKey: "slideDriveSystem") {
        didSet {
            UserDefaults.standard.set(driveSystem, forKey: "slideDriveSystem")
            syncVolume()
        }
    }

    public enum SoundStyle: String, CaseIterable {
        case engine, wheel
        public var label: String { self == .engine ? "跑车引擎" : "鼠标滚轮" }
    }
    /// The engine follows the speed of the slide; the wheel clicks once per step.
    @Published public var soundOn = UserDefaults.standard.object(forKey: "slideSound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(soundOn, forKey: "slideSound")
            if !soundOn {
                sound.stop()
                engineSound.stop()
            }
        }
    }
    @Published public var soundStyle = SoundStyle(rawValue: UserDefaults.standard.string(forKey: "slideSoundStyle") ?? "") ?? .engine {
        didSet {
            UserDefaults.standard.set(soundStyle.rawValue, forKey: "slideSoundStyle")
            sound.stop()
            engineSound.stop()
        }
    }
    private var clicksOn: Bool { soundOn && soundStyle == .wheel }
    @Published public var soundVolume = UserDefaults.standard.object(forKey: "slideSoundVolume") as? Double ?? 0.6 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "slideSoundVolume")
            sound.volume = Float(soundVolume)
            engineSound.volume = Float(soundVolume)
        }
    }
    @Published public var speed = 0.0  // rows per second, smoothed

    /// What a slide does.
    public enum Target: String, CaseIterable {
        case volume, scroll, seek, slides, brightness, tracks
        public var label: String {
            switch self {
            case .volume: return "调节音量"
            case .scroll: return "滚动页面"
            case .seek: return "视频快进"
            case .slides: return "演示翻页"
            case .brightness: return "屏幕亮度"
            case .tracks: return "切换曲目"
            }
        }
        /// Sends keys: a step every so many rows, or one per touch.
        public var isKeys: Bool { self != .volume && self != .scroll }
        public var hint: String {
            switch self {
            case .seek: return "方向键发给最前面的 App：在视频网站、播放器里快退快进。约每 2 mm 一下。"
            case .slides: return "每次滑动翻一页，方向键发给最前面的 App，适用于 Keynote、PowerPoint。"
            case .brightness: return "和键盘的亮度键一样。约每 1 mm 一格。"
            case .tracks: return "每次滑动切一首，和键盘的上一曲、下一曲一样。"
            default: return ""
            }
        }
    }
    @Published public var target = Target(rawValue: UserDefaults.standard.string(forKey: "slideTarget") ?? "") ?? .volume {
        didSet {
            UserDefaults.standard.set(target.rawValue, forKey: "slideTarget")
            if target != .volume && !PageScroller.trusted { PageScroller.requestTrust() }
            scrollTrusted = PageScroller.trusted
        }
    }
    /// Scroll only while a web browser is the front app.
    @Published public var browserOnly = UserDefaults.standard.object(forKey: "slideBrowserOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(browserOnly, forKey: "slideBrowserOnly") }
    }
    /// Page pixels per sensor row (the sensor is 152 rows, about 7.6 mm).
    @Published public var pixelsPerRow = UserDefaults.standard.object(forKey: "slidePixelsPerRow") as? Double ?? 8 {
        didSet { UserDefaults.standard.set(pixelsPerRow, forKey: "slidePixelsPerRow") }
    }
    @Published public private(set) var scrolled = 0.0      // pixels in the current touch
    /// When a touch last scrolled the page: that touch was a slide, not a press to recognise.
    public private(set) var lastScrollAt = Date.distantPast
    /// A touch on the card gives the focus back to the window under the pointer.
    @Published public var refocusOnTouch = UserDefaults.standard.object(forKey: "slideRefocus") as? Bool ?? true {
        didSet { UserDefaults.standard.set(refocusOnTouch, forKey: "slideRefocus") }
    }
    @Published public private(set) var scrollTrusted = PageScroller.trusted
    @Published public private(set) var scrollIdle = ""     // why the last slide did not scroll
    private var clickPixels = 0.0
    private var keyRows = 0.0
    private var ridgeRows = 0.0
    private var keySent = false
    private let scroller = PageScroller()
    static let pixelsPerClick = 40.0

    private let sound = WheelSound()
    private let engineSound = EngineSound()
    private var lastPos: Int32?
    private var lastTime: Date?
    private var moved = 0

    public init() {
        sound.volume = Float(soundVolume)
        engineSound.volume = Float(soundVolume)
        syncVolume()
    }

    /// Start from the volume the Mac has: the keyboard may have changed it since.
    private func syncVolume() {
        if driveSystem, let v = SystemVolume.get() { volume = v * 100 }
    }

    private func keyStep(rows d: Double) {
        scrollTrusted = PageScroller.trusted
        guard scrollTrusted else {
            scrollIdle = "没有“辅助功能”权限，无法发送按键"
            return
        }
        scrollIdle = ""
        keyRows += d
        let up = keyRows > 0
        var fired = 0
        switch target {
        case .seek:
            while abs(keyRows) >= 40 {
                KeySender.press(up ? KeySender.right : KeySender.left)
                keyRows -= up ? 40 : -40
                fired += 1
            }
        case .brightness:
            while abs(keyRows) >= 20 {
                KeySender.press(up ? .brightnessUp : .brightnessDown)
                keyRows -= up ? 20 : -20
                fired += 1
            }
        case .slides where !keySent && abs(keyRows) >= 40:
            KeySender.press(up ? KeySender.right : KeySender.left)
            keySent = true
            fired = 1
        case .tracks where !keySent && abs(keyRows) >= 60:
            KeySender.press(up ? KeySender.Media.next : .previous)
            keySent = true
            fired = 1
        default:
            break
        }
        if fired > 0 {
            lastScrollAt = Date()
            if clicksOn { sound.clicks(fired, over: 0.03) }
        }
    }

    /// Rows the finger must move in one direction before a scroll starts (~0.6 mm).
    static let slopRows = 12.0

    private func scroll(rows d: Double, interval: TimeInterval, reading: PageScroller.Reading, at now: Date) {
        scrollTrusted = PageScroller.trusted
        guard scrollTrusted else {
            scrollIdle = "没有“辅助功能”权限，无法滚动"
            return
        }
        guard !browserOnly || PageScroller.frontIsBrowser else {
            scrollIdle = "最前面的不是浏览器（可以关掉“只在浏览器里滚动”）"
            return
        }
        scrollIdle = ""
        // trackpad-like acceleration: slow movement is finer, fast movement goes further
        let accel = 0.6 + 0.8 * min(1, speed / 250)
        let px = d * pixelsPerRow * accel
        scroller.slop = SlideModel.slopRows * pixelsPerRow
        scroller.gain = pixelsPerRow / 2
        // a still finger (d == 0) still counts: it brings the velocity estimate down
        scroller.move(pixels: px, interval: interval, reading: reading, at: now)
        guard px != 0, scroller.isScrolling else { return }
        scrolled += px
        clickPixels += abs(px)
        let steps = Int(clickPixels / SlideModel.pixelsPerClick)
        if steps > 0 {
            clickPixels -= Double(steps) * SlideModel.pixelsPerClick
            if clicksOn { sound.clicks(steps, over: interval) }
        }
    }

    public func refreshTrust() {
        scrollTrusted = PageScroller.trusted
    }

    public func reset() {
        volume = 50
        if driveSystem { SystemVolume.set(0.5) }
    }

    /// Debugging: `defaults write com.pico-fp-touch.sdfinger slideLogPath /path.csv` logs every
    /// reading (uptime ns, so it lines up with recorded scroll events) for offline replay.
    private lazy var slideLog: FileHandle? = {
        guard let path = UserDefaults.standard.string(forKey: "slideLogPath"), !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: "mono_ns,seq,touching,touch_id,pos,delta,lo,hi,method,frames\n".data(using: .utf8))
        }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }()

    /// `now`: when the reading was polled from the card.
    public func update(_ st: CardMailbox.SlideState, at now: Date = Date()) {
        if let log = slideLog {
            let polled = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - UInt64(max(0, Date().timeIntervalSince(now)) * 1e9)
            let line = "\(polled),\(st.seq),\(st.touching ? 1 : 0),\(st.touchId),\(st.pos),\(st.delta),\(st.lo),\(st.hi),\(st.method),\(st.frames)\n"
            log.write(line.data(using: .utf8)!)
        }
        let interval = lastTime.map { now.timeIntervalSince($0) } ?? 0.026
        if let last = lastPos, let t = lastTime, st.touching {
            // |movement| over time, smoothed over ~80 ms: readings come every ~26 ms and the
            // firmware's position sometimes moves in steps
            let dt = max(0.005, now.timeIntervalSince(t))
            let inst = Double(abs(st.pos &- last)) / dt
            speed += (inst - speed) * (1 - exp(-dt / 0.08))
        } else {
            speed = 0
        }
        lastTime = now
        if st.touching && !touching {
            scrolled = 0
            clickPixels = 0
            keyRows = 0
            keySent = false
            if target == .volume { syncVolume() }
        }
        if target == .scroll, !st.touching, touching {
            scroller.lift(at: now)
        }
        if target == .scroll, st.touching, !touching {
            scroller.touchBegan(at: now)
            if refocusOnTouch { PageScroller.focusUnderPointer() }
        }
        if target == .scroll, st.touching, scroller.isScrolling {
            lastScrollAt = now
        }
        if target.isKeys {
            if let last = lastPos, st.touching {
                keyStep(rows: invert ? -Double(st.pos &- last) : Double(st.pos &- last))
                moved += Int(abs(st.pos &- last))
            }
        } else if target == .scroll, let last = lastPos, st.touching {
            var d = Double(st.pos &- last)
            if invert { d = -d }
            scroll(rows: d, interval: interval,
                   reading: st.method == 1 ? .ridge : st.method == 2 ? .edge : .none, at: now)
        } else if let last = lastPos {
            var d = Double(st.pos &- last)
            if invert { d = -d }
            let v = min(100, max(0, volume + d / rowsPerPercent))
            // a click for every whole percent crossed; none at the end stops
            let steps = abs(Int(v.rounded(.down)) - Int(volume.rounded(.down)))
            if clicksOn && steps > 0 {
                sound.clicks(steps, over: interval)
            }
            if v != volume {
                volume = v
                if driveSystem { SystemVolume.set(v / 100) }
            }
            moved += Int(abs(st.pos &- last))
        }
        // the edges jump as a finger lands: a press must not rev the engine
        if st.touching && !touching { ridgeRows = 0 }
        if st.touching && st.method == 1 { ridgeRows += Double(st.delta) }
        if soundOn && soundStyle == .engine {
            engineSound.update(speed: abs(ridgeRows) >= SlideModel.slopRows ? speed : 0, touching: st.touching)
        }
        lastPos = st.pos
        if st.touching && !touching { moved = 0 }
        touching = st.touching
        span = st.touching ? (st.lo, st.hi) : nil
        trace.append((now, st.pos))
        trace.removeAll { now.timeIntervalSince($0.0) > SlideModel.traceSeconds + 1 }
        let how = [0: "—", 1: "纹路匹配", 2: "接触边缘"][st.method] ?? "?"
        info = "\(st.touching ? "按着" : "抬起")  第 \(st.touchId) 次触摸  本次移动 \(moved) 行  帧位移 \(st.delta > 0 ? "+" : "")\(st.delta)（\(how)）  接触 \(st.lo)-\(st.hi)  速度 \(Int(speed)) 行/秒"
    }
}
