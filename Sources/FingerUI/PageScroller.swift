import AppKit
import ApplicationServices
import QuartzCore

/// Slide movement -> scrolling that feels like a trackpad, delivered to whatever is under
/// the mouse pointer.  Posting events into other apps needs the Accessibility permission.
///
/// The card reports the finger ~70 times a second in whole sensor rows; a hesitant finger
/// reads as "stop for 3-4 frames, then jump 20 rows".  Following that position closely
/// (the first version) turned every hesitation into a hard brake and lurch.  So the output
/// follows the finger's velocity instead: a least-squares slope over the last 120 ms of
/// readings, smoothed, integrated at 120 Hz, with a slow position correction that never
/// pulls the page back against the motion.  Tuned by replaying recorded slides
/// (2026-10-28): half the speed jitter of position following, no bounce-backs, 20-30 ms
/// of lag.  A fast slide is over in 100-250 ms and 4-10 readings, half of them edge
/// readings, so it starts on its first travel at its own speed and catches up faster
/// (replayed 2026-10-31: the page had covered 37% of the finger's travel at the lift, now
/// about 75%).  Events carry trackpad scroll phases, and a flick ends in momentum events that
/// decay like a trackpad's, so browsers treat it as native scrolling.
///
/// Slow slides (2026-11-07, recorded readings and the events this sent, next to a trackpad):
/// a slow finger sticks and slips on the sensor glass, holding still for 100-180 ms and then
/// jumping 6-7 rows (the contact edges hold still too, so it is the finger, not the match).
/// Below slowSpeed the slope looks at 250 ms, which spans a slip or two, and is smoothed
/// more.  A finger that starts fast and slows down (a slide begun mid-sensor) made the page
/// run ahead of it, by 300 px and more, never paid back: now the page may lead the finger by
/// only so much (120 px slow, 60 px fast), each frame's step shrinking as the lead grows,
/// and above slowSpeed the estimate keeps the short window to follow the slowing down.  The
/// start speed comes from ridge readings when there are any: as a finger lands the contact
/// edges spread by tens of rows, which had started a slide at twice the finger's speed.
/// Replayed on two recordings (2026-11-07): lead p99 173/322 -> 67/99 px, stop-go in the
/// page speed 0.12/0.22 -> 0.10/0.19, lag 73 -> 67 ms.  And the events were
/// posted by a 120 Hz timer that ran beside the display's 120 Hz, not with it, stepping a
/// fixed 1/120 s even when the main thread was late: 8% of the display frames of a slide
/// got no scroll and the next one two (the shaking).  A display link on the main thread
/// still missed 7% of the frames, 82% of them while the main thread handled a card reading
/// (the window, sounds); on a thread of its own it came 2-3 ms late or early and dropped to
/// ProMotion's 24-40 Hz, as nothing of this app is on screen.  A trackpad sends every
/// 2-6 ms, not in step with the display either, and Chrome scrolls it smoothly.  So the
/// events now come every 1/240 s from a strict timer on a queue of their own, advanced by
/// the time that really passed; the readings carry the time they were polled, not the time
/// the main thread got to them.  The state is shared under a lock.
final class PageScroller: @unchecked Sendable {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "app.zen-browser.zen",
    ]

    @MainActor static var frontIsBrowser: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { browsers.contains($0) } ?? false
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Bring the app whose window is under the mouse pointer to the front, so scrolling and
    /// the keyboard go back to it (a touch on the card is "I mean this window").
    @MainActor static func focusUnderPointer() {
        let loc = NSEvent.mouseLocation
        guard let mainH = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        let p = CGPoint(x: loc.x, y: mainH - loc.y)   // window bounds are top-left based
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if pid != getpid(), NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
            return
        }
    }

    /// Ask for the permission (System Settings opens with the app listed).
    @MainActor static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // tuning (see the header comment)
    static let tick = 1.0 / 240        // s between events, like a trackpad's ~5 ms
    static let window = 0.12           // s of readings for the velocity slope
    static let slowWindow = 0.25       // the same below slowSpeed: spans the stick-slip
    static let velocitySmoothing = 0.06
    static let slowSmoothing = 0.1     // the same below slowSpeed
    // these three were tuned at 2 px per sensor row and scale with `gain`
    static let slowSpeed = 1000.0      // px/s
    static let maxLead = 60.0          // px the page may get ahead of the finger
    static let slowMaxLead = 120.0     // the same below slowSpeed
    static let correction = 0.15       // s: how fast position drift is taken out
    static let fastCorrection = 0.08   // the same above fastSpeed
    static let fastSpeed = 1500.0      // px/s
    static let staleAfter = 0.3        // s without a measured reading: the finger stopped
    static let momentumDecay = 0.325   // trackpad-like deceleration time constant (s)
    static let momentumMin = 250.0     // px/s at lift for a flick
    static let momentumStop = 12.0     // px/s
    static let startDelay = 0.05       // s after landing before a scroll may start
    static let flickMaxTime = 0.25     // a whole touch this short with enough travel is a flick
    static let flickMaxSpeed = 8000.0  // px/s

    /// What the card measured for a reading (touch_slide.c method).
    enum Reading {
        case ridge   // ridge pattern matched: good position
        case edge    // only the contact edges moved: rough position
        case none    // nothing measurable (landing, or running off the end of the sensor)
    }

    /// Movement (pixels) the finger must make in one direction before anything scrolls,
    /// as a trackpad's scroll hysteresis; a tap's wobble stays inside it.
    var slop: Double {
        get { locked { _slop } }
        set { locked { _slop = newValue } }
    }
    var isScrolling: Bool { locked { mode == .touching } }
    /// Page pixels per sensor row over the 2 the speed and lead limits were tuned at.
    var gain: Double {
        get { locked { _gain } }
        set { locked { _gain = max(0.1, newValue) } }
    }
    private var _gain = 1.0

    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    private var _slop = 96.0

    private enum Mode { case idle, pending, touching, momentum }
    private var mode = Mode.idle
    private var timer: DispatchSourceTimer?
    private static let queue = DispatchQueue(label: "Touch SD scroll", qos: .userInteractive)
    private var lastStep: CFTimeInterval?
    private var target = 0.0           // where the finger is, pixels since the scroll began
    private var out = 0.0              // where the page is (fractional)
    private var sentInt = 0            // pixels already sent (whole)
    private var vs = 0.0               // output velocity, px/s
    private var history: [(t: Date, p: Double)] = []
    private var phaseBegan = false
    private var momentumV = 0.0
    private var momentumBegan = false
    private var touchStart = Date()
    private var pendingNet = 0.0
    // the whole touch, for flicks too quick for the scroll to get going (2-4 card frames)
    private var touchNet = 0.0
    private var steps = 0              // readings of real movement in the touch's direction
    private var firstMove: Date?
    private var lastMove = Date()
    private var ridgeNet = 0.0         // ridge-matched travel before the scroll started
    private var firstRidge: Date?

    /// A finger landed.  Like grabbing a trackpad: any glide stops.
    func touchBegan(at now: Date = Date()) {
        locked { begin(now) }
    }

    private func begin(_ now: Date) {
        if mode == .momentum { endMomentum() }
        if mode == .touching, phaseBegan { send(0, phase: .ended) }
        mode = .pending
        phaseBegan = false
        touchStart = now
        pendingNet = 0
        touchNet = 0
        steps = 0
        firstMove = nil
        ridgeNet = 0
        firstRidge = nil
        history.removeAll()
        target = 0
        out = 0
        sentInt = 0
        vs = 0
        stopTimer()
    }

    /// A reading while the finger is down: `pixels` is the movement since the previous
    /// one, > 0 towards the end of the page.
    func move(pixels: Double, interval: TimeInterval, reading: Reading, at now: Date = Date()) {
        locked { moveLocked(pixels: pixels, interval: interval, reading: reading, now: now) }
    }

    private func moveLocked(pixels: Double, interval: TimeInterval, reading: Reading, now: Date) {
        if mode != .pending && mode != .touching { begin(now) }
        let slop = _slop
        var reading = reading, px = pixels
        // Running off the end, the leading edge is clipped and only the trailing edge moves:
        // an edge reading against the motion is that, not the finger turning round.
        if reading == .edge && ((vs * px < 0 && abs(vs) > 60) || (touchNet * px < 0 && abs(touchNet) > slop / 2)) {
            reading = .none
            px = 0
        }
        if reading != .none && px != 0 {
            if firstMove == nil { firstMove = now.addingTimeInterval(-max(0.008, min(interval, 0.05))) }
            lastMove = now
            touchNet += px
            if touchNet * px > 0 && abs(px) >= slop * 0.15 { steps += 1 }
        }
        switch mode {
        case .pending:
            // only ridge readings count here: landing makes the contact edges jump
            if reading == .ridge {
                pendingNet += px
                if px != 0 {
                    if firstRidge == nil { firstRidge = now.addingTimeInterval(-max(0.008, min(interval, 0.05))) }
                    ridgeNet += px
                }
            }
            // ... unless the finger is plainly on its way, on too few ridge readings to wait for
            let fast = abs(touchNet) >= 2 * slop && steps >= 2
            if (abs(pendingNet) >= slop || fast) && now.timeIntervalSince(touchStart) >= PageScroller.startDelay {
                mode = .touching
                let travel = abs(pendingNet) >= slop ? pendingNet : touchNet
                target = travel - (travel > 0 ? slop : -slop)   // start from here, no jump
                out = 0
                sentInt = 0
                // already at the finger's speed: from zero the smoothing would lose the slide;
                // measured on the ridges when it can be, the landing spreads the edges
                if abs(pendingNet) >= slop, let r = firstRidge {
                    vs = limit(ridgeNet / max(0.03, now.timeIntervalSince(r)))
                } else {
                    vs = firstMove.map { limit(touchNet / max(0.03, now.timeIntervalSince($0))) } ?? 0
                }
                phaseBegan = false
                history = [(now, target)]
                startTimer()
            }
        case .touching:
            target += px
            if reading != .none { history.append((now, target)) }
        default:
            break
        }
    }

    /// Least-squares slope of the recent readings (px/s); 0 once they are stale.
    private func fingerVelocity(_ now: Date) -> Double {
        let window = abs(vs) < PageScroller.slowSpeed * _gain ? PageScroller.slowWindow : PageScroller.window
        history.removeAll { now.timeIntervalSince($0.t) > window }
        guard let last = history.last, now.timeIntervalSince(last.t) < PageScroller.staleAfter else { return 0 }
        guard history.count >= 2, let first = history.first, last.t.timeIntervalSince(first.t) > 0.03 else {
            return vs
        }
        let ts = history.map { $0.t.timeIntervalSince(first.t) }
        let n = Double(ts.count)
        let mt = ts.reduce(0, +) / n, mp = history.reduce(0) { $0 + $1.p } / n
        var num = 0.0, den = 0.0
        for (t, h) in zip(ts, history) {
            num += (t - mt) * (h.p - mp)
            den += (t - mt) * (t - mt)
        }
        return den > 0 ? num / den : vs
    }

    /// The finger lifted.
    func lift(at now: Date = Date()) {
        locked { liftLocked() }
    }

    private func liftLocked() {
        let slop = _slop
        // a quick flick: the touch was short, so judge it by its travel over its duration
        var flickV: Double?
        if let f = firstMove {
            let dur = max(0.03, lastMove.timeIntervalSince(f))
            if dur <= PageScroller.flickMaxTime && abs(touchNet) >= 2 * slop {
                flickV = limit(touchNet / dur)
            }
        }
        if mode == .pending {
            guard let v = flickV, abs(v) >= PageScroller.momentumMin else {
                mode = .idle    // a tap
                return
            }
            // never got going: a one-pixel gesture so apps see began/ended, then the glide
            send(v > 0 ? 1 : -1, phase: .began)
            send(0, phase: .ended)
            startMomentum(v)
            return
        }
        guard mode == .touching else { return }
        if phaseBegan { send(0, phase: .ended) }
        phaseBegan = false
        // glide on at the current speed (no dip), or the flick's if the output had not caught
        // up with it, and never pay distance back
        var v = vs
        if let f = flickV, abs(f) > abs(vs) { v = f }
        if abs(v) >= PageScroller.momentumMin {
            startMomentum(v)
        } else {
            mode = .idle
            stopTimer()
        }
    }

    private func limit(_ v: Double) -> Double {
        max(-PageScroller.flickMaxSpeed, min(PageScroller.flickMaxSpeed, v))
    }

    private func startMomentum(_ v: Double) {
        mode = .momentum
        momentumV = v
        momentumBegan = false
        out = 0
        sentInt = 0
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastStep = nil
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: PageScroller.queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1e9 * PageScroller.tick)),
                   leeway: .microseconds(200))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.locked {
                if self.mode == .touching || self.mode == .momentum {
                    self.tick(CACurrentMediaTime())
                } else {
                    self.stopTimer()
                }
            }
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        lastStep = nil
    }

    /// A tick at `now` (host seconds): step by the time since the last.
    private func tick(_ now: CFTimeInterval) {
        let dt = lastStep.map { min(0.05, max(0.001, now - $0)) } ?? PageScroller.tick
        lastStep = now
        step(dt, at: Date().addingTimeInterval(now - CACurrentMediaTime()))
    }

    private func step(_ dt: Double, at date: Date) {
        switch mode {
        case .idle, .pending:
            stopTimer()
        case .touching:
            let v = fingerVelocity(date)
            let slow = abs(vs) < PageScroller.slowSpeed * _gain
            let smoothing = slow ? PageScroller.slowSmoothing : PageScroller.velocitySmoothing
            vs = limit(vs + (v - vs) * (1 - exp(-dt / smoothing)))
            let fast = abs(vs) >= PageScroller.fastSpeed
            var corr = (target - out) * (dt / (fast ? PageScroller.fastCorrection : PageScroller.correction))
            if abs(vs) < 20 || corr * vs < 0 { corr = 0 }   // never pull the page back
            // ahead of the finger: slow down, to a stop at the limit (the estimate is kept,
            // so a slip that catches up carries on at once)
            let lead = (out - target) * (vs < 0 ? -1 : 1)
            let maxLead = (slow ? PageScroller.slowMaxLead : PageScroller.maxLead) * _gain
            let scale = lead <= 0 ? 1 : max(0, 1 - lead / maxLead)
            out += vs * dt * scale + corr
            emit { self.send($0, phase: self.phaseBegan ? .changed : .began); self.phaseBegan = true }
        case .momentum:
            momentumV *= exp(-dt / PageScroller.momentumDecay)
            out += momentumV * dt
            emit { self.sendMomentum($0, phase: self.momentumBegan ? 2 : 1); self.momentumBegan = true }
            if abs(momentumV) < PageScroller.momentumStop {
                endMomentum()
                mode = .idle
                stopTimer()
            }
        }
    }

    private func emit(_ send: (Int) -> Void) {
        let whole = Int(out.rounded(.towardZero))
        let d = whole - sentInt
        if d != 0 {
            send(d)
            sentInt = whole
        }
    }

    private func endMomentum() {
        if momentumBegan { sendMomentum(0, phase: 3) }
        momentumBegan = false
        momentumV = 0
    }

    private enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    private func event(_ px: Int) -> CGEvent? {
        // wheel1 > 0 moves the content down (towards the top): ours is the opposite sign
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(-px), wheel2: 0, wheel3: 0) else { return nil }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return ev
    }

    private func send(_ px: Int, phase: Phase) {
        guard let ev = event(px) else { return }
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        ev.post(tap: .cghidEventTap)
    }

    /// Momentum phase: 1 begin, 2 continue, 3 end.
    private func sendMomentum(_ px: Int, phase: Int64) {
        guard let ev = event(px) else { return }
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase)
        ev.post(tap: .cghidEventTap)
    }
}
