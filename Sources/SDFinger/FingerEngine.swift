import CoreGraphics
@preconcurrency import CvBridge
@preconcurrency import FingerCore
import Foundation

/// A finger as the UI lists it.
struct FingerInfo: Identifiable, Equatable {
    let id: Int
    let name: String
    let samples: Int
    let created: String
}

/// Matching, enrolment and the sealed template store, on one serial queue (the OpenCV
/// work takes tens of milliseconds per press).  Results come back on the main queue.
final class FingerEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "sdfinger.engine", qos: .userInitiated)
    private var settings: Settings
    private var store: SealedStore?
    private var verify: VerifySession
    private var enroll: EnrollSession?
    private var mosaic: FPMosaic?
    private var dataKey: Data?
    private let keys: StoreKeys
    private let storeURL: URL

    /// The fingers exist in the clear only while the card is connected.
    enum StoreState: Equatable {
        case locked                 // no card yet
        case open
        case orphan                 // this card cannot open the file: enrol again
        case failed(String)
    }

    init(directory: URL) {
        settings = Settings(path: directory.appendingPathComponent("settings.json"))
        verify = VerifySession(settings: settings)
        storeURL = directory.appendingPathComponent("fingers.sealed")
        keys = StoreKeys(url: directory.appendingPathComponent("fingers.keys"))
    }

    func salt(card: String, _ done: @escaping (Data) -> Void) {
        queue.async {
            let s = self.keys.salt(card: card)
            self.main { done(s) }
        }
    }

    /// The card has answered for `salt`: open the file, or start a new one.  The keychain
    /// may ask the user first, so never on the main thread.
    func unlock(card: String, salt: Data, secret: Data, _ done: @escaping (StoreState) -> Void) {
        queue.async {
            let state = self.openStore(card: card, salt: salt, secret: secret)
            self.main { done(state) }
        }
    }

    private func newKey() -> Data {
        var k = Data(count: 32)
        k.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return k
    }

    private func openStore(card: String, salt: Data, secret: Data) -> StoreState {
        do {
            let local = try Keychain.key("fingers-local-key")
            if let key = keys.open(card: card, secret: secret, local: local) {
                if store == nil {
                    store = try SealedStore(url: storeURL, key: key, params: settings.params)
                }
                dataKey = key
                return .open
            }
            // still in memory across a new pairing of the same card or another one
            if let key = dataKey, store != nil {
                try keys.add(card: card, key: key, salt: salt, secret: secret, local: local)
                return .open
            }
            if FileManager.default.fileExists(atPath: storeURL.path) {
                // from before the file was bound to a card
                guard !keys.has(card: card), let old = try Keychain.get("templates-key") else { return .orphan }
                let s = try SealedStore(url: storeURL, key: old, params: settings.params)
                let key = newKey()
                try keys.add(card: card, key: key, salt: salt, secret: secret, local: local)
                try s.rekey(key)
                store = s
                dataKey = key
                return .open
            }
            let key = newKey()
            try keys.add(card: card, key: key, salt: salt, secret: secret, local: local)
            store = try SealedStore(url: storeURL, key: key, params: settings.params)
            dataKey = key
            return .open
        } catch {
            return .failed("\(error)")
        }
    }

    /// The card went away.  An enrolment under way keeps what it has until it ends.
    func lock(_ done: @escaping () -> Void) {
        queue.async {
            if self.enroll == nil {
                self.store = nil
                self.dataKey = nil
            }
            self.main(done)
        }
    }

    /// Give up on a file no card can open, and start a new one for this card.
    func discardStore(card: String, salt: Data, secret: Data, _ done: @escaping (StoreState) -> Void) {
        queue.async {
            self.store = nil
            self.dataKey = nil
            self.keys.removeAll()
            try? FileManager.default.removeItem(at: self.storeURL)
            let state = self.openStore(card: card, salt: self.keys.salt(card: card), secret: secret)
            self.main { done(state) }
        }
    }

    private func main(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    var maxFingers: Int { settings.int("max_fingers") }
    var enrollSteps: Int { settings.int("enroll_steps") }

    func fingers(_ done: @escaping ([FingerInfo]) -> Void) {
        queue.async {
            let list = (self.store?.fingers ?? []).map {
                FingerInfo(id: $0.id, name: $0.name, samples: $0.samples.count, created: $0.created)
            }
            self.main { done(list) }
        }
    }

    // MARK: unlock

    struct Verdict {
        let kind: ResultKind
        let message: String
        let finger: String?
        var fingerId: Int? = nil
    }

    /// One press against every enrolled finger.  An accepted press that adds coverage
    /// joins the template.  No scores leave this function: the UI only learns pass, fail
    /// or why to try again (anti hill-climbing, SECURITY_DESIGN 7.3).
    func verify(_ raw: Data, _ done: @escaping (Verdict) -> Void) {
        queue.async {
            guard let store = self.store, !store.fingers.isEmpty else {
                self.main { done(Verdict(kind: .help, message: self.store == nil ? "指纹库还没有解开" : "还没有录入指纹", finger: nil)) }
                return
            }
            let r = self.verify.onTouch([raw], fingers: store.fingers)
            if r.kind == .match, r.learn, let g = r.finger, let s = r.learnSample {
                try? store.append(g, s)
            }
            let v = Verdict(kind: r.kind, message: r.message, finger: r.finger?.name, fingerId: r.finger?.id)
            self.main { done(v) }
        }
    }

    func resetLockout() {
        queue.async { self.verify.reset() }
    }

    var lockedLeft: TimeInterval { queue.sync { verify.lockedLeft } }

    // MARK: enrolment

    struct EnrollUpdate {
        let kind: ResultKind
        let message: String
        let done: Int
        let steps: Int
        let stage: Stage
        let mosaic: CGImage?
        let finger: FingerInfo?
    }

    func startEnroll() {
        queue.async {
            self.enroll = EnrollSession(settings: self.settings)
            self.mosaic = FPMosaic(params: self.settings.params)
        }
    }

    func cancelEnroll() {
        queue.async {
            self.enroll = nil
            self.mosaic = nil
        }
    }

    func enrollTouch(_ raw: Data, _ done: @escaping (EnrollUpdate) -> Void) {
        queue.async {
            guard let e = self.enroll, let mo = self.mosaic else { return }
            let r = e.onTouch(raw)
            var image: CGImage?
            if r.kind != .help, let s = r.sample {
                mo.add(s)
                var w = 0, h = 0, area = 0.0
                var alone: ObjCBool = false
                var islands: NSArray?
                if let d = mo.render(r.kind == .done ? -1 : mo.count - 1, width: &w, height: &h, area: &area,
                                     islands: &islands, highlightAlone: &alone) {
                    image = Images.rgba(d, width: w, height: h)
                }
            }
            var added: FingerInfo?
            var message = r.message
            if r.kind == .done {
                do {
                    if let g = try self.store?.add(e.samples) {
                        added = FingerInfo(id: g.id, name: g.name, samples: g.samples.count, created: g.created)
                    }
                } catch {
                    message = "保存失败：\(error)"
                }
                self.enroll = nil
                self.mosaic = nil
            }
            let u = EnrollUpdate(kind: r.kind, message: message, done: e.done, steps: e.steps,
                                 stage: e.stage.1, mosaic: image, finger: added)
            self.main { done(u) }
        }
    }

    // MARK: library

    func rename(_ id: Int, _ name: String, _ done: @escaping () -> Void) {
        queue.async {
            if let g = self.store?.fingers.first(where: { $0.id == id }) { try? self.store?.rename(g, name) }
            self.main(done)
        }
    }

    func delete(_ id: Int, _ done: @escaping () -> Void) {
        queue.async {
            if let g = self.store?.fingers.first(where: { $0.id == id }) { try? self.store?.remove(g) }
            self.main(done)
        }
    }

    func deleteAll(_ done: @escaping () -> Void) {
        queue.async {
            try? self.store?.removeAll()
            self.main(done)
        }
    }

    /// Development convenience: take the fingers of an fpdb/ folder (host/fpgui, the lab
    /// app) into the sealed store.
    func importPlain(_ dir: URL, _ done: @escaping (Int) -> Void) {
        queue.async {
            let plain = Store(root: dir, params: self.settings.params)
            var n = 0
            for g in plain.fingers where !g.samples.isEmpty {
                if (try? self.store?.add(g.samples, name: g.name)) != nil { n += 1 }
            }
            self.main { done(n) }
        }
    }
}
