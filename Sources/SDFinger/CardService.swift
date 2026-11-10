import AppKit
@preconcurrency import FingerCore
import Foundation

/// The card, as the rest of the app sees it.
enum CardState: Equatable {
    case absent
    case outdated(String)                          // firmware without the secure channel
    case unpaired(SecureCard.Identity)
    case paired(SecureCard.Identity, PairedCard)   // session open
    case failed(String)
}

/// One finished press: the decrypted frame of the card's press `press`.
struct Press {
    let press: UInt32
    let raw: Data          // 152 x 35 grey, as the matcher wants it
    let slid: Bool         // the finger moved along the sensor: a slide, not a press
}

/// Owns the card: finds the volume, opens the secure session, keeps it alive, polls the
/// slide state and the sealed frames, and runs requests one at a time on its own queue.
/// Everything it reports arrives on the main queue.
final class CardService: @unchecked Sendable {
    var onState: ((CardState) -> Void)?
    /// A slide reading, with when it was polled (the main thread may get to it later).
    var onSlide: ((CardMailbox.SlideState, Date) -> Void)?
    var onPress: ((Press) -> Void)?
    var onTouch: ((Bool) -> Void)?
    /// Something wants the next press recognised.  Reading a frame stalls the SD bus for
    /// ~10 ms, which a slide would feel, so without a taker frames are left on the card.
    var wantFrames = false
    /// The live view is open: every frame goes to onLive, and the frame of a press waits
    /// for the end of the touch, as a slide cannot be told from a press before that.
    var liveWanted = false
    private var heldPress: Press?
    var onLive: ((Data) -> Void)?
    private(set) var resetCancelled = false

    let queue = DispatchQueue(label: "sdfinger.card", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var mailbox: CardMailbox?
    private var session: SecureCard.Session?
    private var identity: SecureCard.Identity?
    private var paired: PairedCard?
    private var state = CardState.absent
    private var paused = false
    private var tick = 0
    private var lastImageSeq: UInt32?
    private var liveOn = false
    private var ledWanted: [UInt8]?
    private var ledSent: [UInt8]?
    private var lastLED = Date.distantPast
    private var lastLive = Date.distantPast
    private var lastSlideSeq: UInt32?
    private var lastPing = Date()
    private var nextAttempt = Date.distantPast
    // slide vs press: movement of the current touch, and a frame held until the touch ends
    private var touching = false
    private var ridgeTravel: Int32 = 0
    private var touchMoved: Int32 = 0
    private var pending: (seq: UInt32, at: Date, tries: Int)?   // a frame not read yet
    private var lastTouchEnd = Date.distantPast

    static let slideRows: Int32 = 12   // as the scroll slop (SlideModel.slopRows)

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.nextAttempt = .distantPast }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: polling (card queue)

    private func set(_ s: CardState) {
        guard s != state else { return }
        state = s
        DispatchQueue.main.async { self.onState?(s) }
    }

    private func drop(_ why: CardState) {
        session = nil
        mailbox = nil
        identity = nil
        paired = nil
        pending = nil
        touching = false
        set(why)
        nextAttempt = Date().addingTimeInterval(2)
    }

    private func connect() {
        guard Date() >= nextAttempt else { return }
        nextAttempt = Date().addingTimeInterval(2)
        guard FileManager.default.fileExists(atPath: CardMailbox.volume + "/HOSTOUT.BIN") else {
            if state != .absent { drop(.absent) }
            return
        }
        do {
            let mb = try CardMailbox()
            let id: SecureCard.Identity
            do {
                id = try SecureCard.identity(mb)
            } catch let e as SecureCard.Failure {
                mailbox = nil
                set(.outdated(e.description))
                return
            }
            mailbox = mb
            identity = id
            lastImageSeq = try mb.slideState()?.imageSeq
            guard let p = PairedCard.find(id) else {
                set(.unpaired(id))
                return
            }
            paired = p
            session = try SecureCard.open(mb, hostId: p.hostId, kPair: p.kPair)
            lastPing = Date()
            set(.paired(id, p))
        } catch {
            // "not paired" from the card: it was reset, or unpaired from another Mac
            if "\(error)".contains("not paired"), let id = identity {
                PairedCard.find(id)?.forget()
                paired = nil
                set(.unpaired(id))
                return
            }
            drop(.failed("\(error)"))
        }
    }

    private func poll() {
        if paused { return }
        if mailbox == nil || (paired != nil && session == nil) {
            connect()
            if mailbox == nil { return }
        }
        guard let mb = mailbox else { return }
        tick += 1
        // The card has a new reading about every 25 ms: polling at that rate as well would
        // beat with it and hand on some readings a whole period late.  Nothing happens
        // between touches, so 50 ms then.
        let busy = touching || pending != nil || Date().timeIntervalSince(lastTouchEnd) < 1
        if !busy && tick % 5 != 0 { return }
        do {
            if let st = try mb.slideState() {
                if st.seq != lastSlideSeq {
                    lastSlideSeq = st.seq
                    trackTouch(st)
                    let polled = Date()
                    DispatchQueue.main.async { self.onSlide?(st, polled) }
                }
                if let seq = st.imageSeq, seq != lastImageSeq {
                    lastImageSeq = seq
                    if liveWanted, let s = session {
                        pending = nil
                        if let f = try s.readFrame() {
                            let raw = FrameImage.raw(fromFrame: f.frame)
                            if f.press != 0 { heldPress = Press(press: f.press, raw: raw, slid: false) }
                            DispatchQueue.main.async { self.onLive?(raw) }
                        }
                    } else {
                        pending = wantFrames ? (seq, Date(), 0) : nil
                    }
                }
            }
            if let s = session {
                if liveWanted, Date().timeIntervalSince(lastLive) > 1 {
                    lastLive = Date()
                    liveOn = true
                    try s.setLive(true)
                } else if !liveWanted && liveOn {
                    liveOn = false
                    lastLive = .distantPast
                    try s.setLive(false)
                }
                syncLEDs(s)
                try takeFrame(s)
                if Date().timeIntervalSince(lastPing) > 20 {
                    lastPing = Date()
                    try s.ping()
                }
                if s.closed { session = nil }
            }
        } catch {
            if !FileManager.default.fileExists(atPath: CardMailbox.volume) {
                drop(.absent)
            } else if session != nil {
                session = nil       // reopened on the next tick
            } else {
                drop(.failed("\(error)"))
            }
        }
    }

    /// nil hands the LEDs back to the firmware.
    func setLEDs(_ rgb: [UInt8]?) {
        queue.async { self.ledWanted = rgb }
    }

    /// Not `try`: a colour that did not arrive is no reason to reopen the session.
    private func syncLEDs(_ s: SecureCard.Session) {
        if let c = ledWanted {
            guard c != ledSent || Date().timeIntervalSince(lastLED) > 1 else { return }
            lastLED = Date()
            ledSent = c
            try? s.setLEDs(c)
        } else if ledSent != nil {
            ledSent = nil
            try? s.releaseLEDs()
        }
    }

    /// The frame of a press is published ~0.1 s into the touch, before it can be told from
    /// a slide; wait until the touch has ended or stayed put.  A slide never reads it.
    private func takeFrame(_ s: SecureCard.Session) throws {
        guard let p = pending, !touching || Date().timeIntervalSince(p.at) > 0.35 else { return }
        if touchMoved > CardService.slideRows {
            pending = nil
            return
        }
        guard let f = try s.readFrame() else {
            // mid-write, or replaced while it was being read
            pending = p.tries < 2 ? (p.seq, p.at, p.tries + 1) : nil
            return
        }
        pending = nil
        let press = Press(press: f.press, raw: FrameImage.raw(fromFrame: f.frame), slid: false)
        DispatchQueue.main.async { self.onPress?(press) }
    }

    private func trackTouch(_ st: CardMailbox.SlideState) {
        if st.touching && !touching {
            ridgeTravel = 0
            touchMoved = 0
            DispatchQueue.main.async { self.onTouch?(true) }
        }
        if st.touching {
            // ridge matches only: the contact edges jump tens of rows as any finger lands
            if st.method == 1 { ridgeTravel &+= Int32(st.delta) }
            touchMoved = max(touchMoved, abs(ridgeTravel))
        } else if touching {
            if let p = heldPress, wantFrames, touchMoved <= CardService.slideRows {
                DispatchQueue.main.async { self.onPress?(p) }
            }
            heldPress = nil
            lastTouchEnd = Date()
            DispatchQueue.main.async { self.onTouch?(false) }
        }
        touching = st.touching
    }

    // MARK: requests (from the main queue)

    private func run<T>(_ body: @escaping () throws -> T, _ done: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let r = Result { try body() }
            DispatchQueue.main.async { done(r) }
        }
    }

    func beginPairing(_ done: @escaping (Result<SecureCard.Pairing, Error>) -> Void) {
        run({
            guard let mb = self.mailbox else { throw SecureCard.Failure("没有插卡") }
            var hostId = Data(count: 16)
            hostId.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return try SecureCard.beginPairing(mb, hostId: hostId)
        }, done)
    }

    func confirmPairing(_ p: SecureCard.Pairing, name: String,
                        _ done: @escaping (Result<Bool, Error>) -> Void) {
        run({
            guard let mb = self.mailbox else { throw SecureCard.Failure("卡被拔出了") }
            switch try SecureCard.confirm(mb, p) {
            case .waitingForPress:
                return false
            case .paired(let p):
                try PairedCard(name: name, pairing: p).save()
                self.nextAttempt = .distantPast
                self.session = nil
                self.mailbox = nil      // reconnect: now paired, opens a session
                return true
            }
        }, done)
    }

    func cancelPairing() {
        queue.async { if let mb = self.mailbox { SecureCard.cancelPairing(mb) } }
    }

    /// Arm the card's factory reset and wait for the finger.  Needs no pairing and works on a
    /// card whose keystore does not open, where there is no mailbox yet.  True when it is done.
    func factoryReset(onHold: @escaping (Bool) -> Void, _ done: @escaping (Result<Bool, Error>) -> Void) {
        resetCancelled = false
        run({
            let mb = try self.mailbox ?? CardMailbox()
            let start = try SecureCard.armReset(mb)
            var holding = false
            var misses = 0
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                if self.resetCancelled {
                    SecureCard.cancelReset(mb)
                    return false
                }
                // the card does not answer while it makes the new identity
                guard let s = try? SecureCard.resetState(mb) else {
                    misses += 1
                    if misses > 8 { throw SecureCard.Failure("卡没有回应") }
                    continue
                }
                misses = 0
                if s.done != start.done {
                    self.session = nil
                    self.mailbox = nil
                    self.identity = nil
                    self.paired = nil
                    self.touching = false
                    self.nextAttempt = .distantPast
                    return true
                }
                if !s.armed { return false }
                if s.holding != holding {
                    holding = s.holding
                    let h = holding
                    DispatchQueue.main.async { onHold(h) }
                }
            }
        }, done)
    }

    func cancelFactoryReset() { resetCancelled = true }

    func secret(press: UInt32, salt: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        run({
            guard let s = self.session else { throw SecureCard.Failure("卡没有连上") }
            return try s.secret(press: press, salt: salt)
        }, done)
    }

    func sign(press: UInt32, challenge: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        run({
            guard let s = self.session else { throw SecureCard.Failure("卡没有连上") }
            return try s.sign(press: press, challenge: challenge)
        }, done)
    }

    func storeSecret(salt: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        run({
            guard let s = self.session else { throw SecureCard.Failure("卡没有连上") }
            return try s.storeSecret(salt: salt)
        }, done)
    }

    func sshPublic(_ done: @escaping (Result<Data, Error>) -> Void) {
        run({
            guard let s = self.session else { throw SecureCard.Failure("卡没有连上") }
            return try s.sshPublic()
        }, done)
    }

    func sshSign(press: UInt32, digest: Data, _ done: @escaping (Result<Data, Error>) -> Void) {
        run({
            guard let s = self.session else { throw SecureCard.Failure("卡没有连上") }
            return try s.sshSign(press: press, digest: digest)
        }, done)
    }

    func unpair(_ done: @escaping (Result<Void, Error>) -> Void) {
        run({
            guard let s = self.session, let p = self.paired else { throw SecureCard.Failure("卡没有连上") }
            try s.unpair()
            p.forget()
            self.session = nil
            self.mailbox = nil
            self.nextAttempt = .distantPast
        }, done)
    }

    /// Forget a card that is not here (lost): only this Mac's half of the pairing.
    func forget(_ card: PairedCard) {
        queue.async {
            card.forget()
            if self.paired == card {
                self.session = nil
                self.mailbox = nil
                self.nextAttempt = .distantPast
            }
        }
    }

    func statusText(_ done: @escaping (Result<String, Error>) -> Void) {
        run({
            guard let mb = self.mailbox else { throw SecureCard.Failure("没有插卡") }
            return try mb.statusText()
        }, done)
    }

    /// Stop touching the card (firmware update), then resume.
    func pause(_ done: @escaping () -> Void) {
        queue.async {
            self.session?.close()
            self.session = nil
            self.mailbox = nil
            self.paused = true
            DispatchQueue.main.async(execute: done)
        }
    }

    func resume() {
        queue.async {
            self.paused = false
            self.nextAttempt = .distantPast
        }
    }

    func shutdown() {
        queue.sync {
            session?.close()
            session = nil
            mailbox = nil
        }
    }
}
