import AppKit
@preconcurrency import FingerCore
import FingerUI
import LocalAuthentication
import ServiceManagement
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, fingers, vault, actions, sudo, dev, slide, device, security
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "概览"
        case .fingers: return "指纹"
        case .vault: return "保险箱"
        case .actions: return "解锁动作"
        case .sudo: return "sudo"
        case .dev: return "SSH 与确认"
        case .slide: return "滑动控制"
        case .device: return "设备"
        case .security: return "安全说明"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "sdcard"
        case .fingers: return "touchid"
        case .vault: return "lock.rectangle.stack"
        case .actions: return "bolt"
        case .sudo: return "terminal"
        case .dev: return "key.viewfinder"
        case .slide: return "slider.horizontal.3"
        case .device: return "cpu"
        case .security: return "checkmark.shield"
        }
    }
}

/// What the next press is for, most urgent first.
enum Purpose: Equatable {
    case sudo, gate, vaultCreate, vaultOpen, vaultRewrap, enroll, unlock, none
}

struct Feedback: Equatable {
    enum Tone { case ok, fail, info }
    let tone: Tone
    let title: String
    let detail: String
    let at = Date()
}

struct PairingFlow {
    enum Step: Equatable {
        case starting, compare, waitingPress, done, failed(String)
    }
    var step = Step.starting
    var colors: [SecureCard.SASColor] = []
    var cardKey = ""
    var pairing: SecureCard.Pairing?
}

struct EnrollFlow {
    var done = 0
    var steps = 32
    var title = "将指腹中间放在传感器上"
    var detail = "每次抬起手指后，稍微挪动一下位置再按"
    var hint = ""
    var hintIsProblem = false
    var mosaic: CGImage?
    var finished: FingerInfo?
    var progress: Double { steps > 0 ? Double(done) / Double(steps) : 0 }
}

@MainActor
final class AppState: ObservableObject {
    static let directory: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SD Finger")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()

    let card = CardService()
    private(set) var engine: FingerEngine!
    let vault = Vault(directory: AppState.directory)
    let actions = Actions()
    let slide: SlideModel = {
        UserDefaults.standard.register(defaults: ["slideDriveSystem": true])
        return SlideModel()
    }()
    let sudo = SudoBridge(directory: AppState.directory)
    let ssh = SSHAgent(directory: AppState.directory)
    let confirm = ConfirmBridge(directory: AppState.directory)
    let hud = HUDPanel()

    @Published var page: Page = .home
    @Published private(set) var cardState = CardState.absent
    @Published private(set) var fingers: [FingerInfo] = []
    @Published private(set) var fingerStore = FingerEngine.StoreState.locked
    private var keepFingers = false       // reset or unpaired: carry them to the next pairing
    @Published private(set) var touching = false
    @Published var feedback: Feedback?
    @Published var pairing: PairingFlow?
    @Published var enroll: EnrollFlow?
    @Published private(set) var vaultWaiting: Purpose?
    @Published private(set) var sudoPending: SudoBridge.Request?
    @Published private(set) var sudoInstalled = SudoBridge.installed
    /// Someone waits for a press: an SSH signature or `sdfinger confirm`.
    struct Gate {
        let title: String
        let detail: String
        let digest: Data?    // an SSH signature
        let reply: (Result<Data, Error>) -> Void
    }
    @Published private(set) var gatePending: Gate?
    @Published private(set) var sshKey: Data?
    let camera = LiveCamera()
    let leds = CardLEDs()
    @Published var sshEnabled = UserDefaults.standard.bool(forKey: "sshEnabled") {
        didSet {
            UserDefaults.standard.set(sshEnabled, forKey: "sshEnabled")
            if sshEnabled { ssh.server.start() } else { ssh.server.stop() }
        }
    }
    @Published var lockOnRemove = UserDefaults.standard.bool(forKey: "lockOnRemove") {
        didSet { UserDefaults.standard.set(lockOnRemove, forKey: "lockOnRemove") }
    }
    @Published var unlockTestVisible = false
    @Published var alertText: String?
    @Published var updateLog: [String] = []
    @Published var updating = false
    enum ResetStage { case waiting, holding }
    @Published var resetStage: ResetStage?

    @Published var showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var sudoTimer: Timer?
    private var sudoFails = 0
    private var gateTimer: Timer?
    private var gateFails = 0
    private var noLockUntil = Date.distantPast   // the card goes away with the Mac's sleep too

    init() {
        engine = FingerEngine(directory: AppState.directory)
        card.onState = { [weak self] s in self?.cardChanged(s) }
        card.onSlide = { [weak self] st, polled in self?.slide.update(st, at: polled) }
        card.onTouch = { [weak self] down in self?.touching = down }
        card.onPress = { [weak self] p in self?.handle(p) }
        card.onLive = { [weak self] raw in self?.camera.push(raw) }
        leds.apply = { [weak self] rgb in self?.card.setLEDs(rgb) }
        sudo.onRequest = { [weak self] r in self?.sudoRequest(r) }
        ssh.onSign = { [weak self] r in
            self?.gateRequest(Gate(title: "SSH 签名", detail: "\(r.peer) · 在指纹卡上按一下手指", digest: r.digest, reply: r.reply))
        }
        confirm.onRequest = { [weak self] r in
            self?.gateRequest(Gate(title: r.reason.isEmpty ? "确认操作" : r.reason, detail: "\(r.peer) · 在指纹卡上按一下手指",
                                   digest: nil) { res in r.reply(res.map { _ in }) })
        }
        actions.code = { [weak self] id in
            self?.vault.touch()
            return self?.vault.items.first { $0.id == id }?.code?.code()
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noLockUntil = Date().addingTimeInterval(20) }
            }
        }
        card.start()
        sudo.start()
        confirm.server.start()
        if sshEnabled { ssh.server.start() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.card.wantFrames = self.purpose != .none
                // a closed window stays in the list and SwiftUI does not always say it went
                let open = NSApp.windows.contains {
                    $0.title == CameraView.title && $0.isVisible && !$0.isMiniaturized
                }
                if !open && self.camera.image != nil { self.camera.clear() }
                // a press someone is waiting for comes first
                self.card.liveWanted = open && self.sudoPending == nil && self.gatePending == nil
                    && self.vaultWaiting == nil && self.enroll == nil
            }
        }
    }

    func shutdown() {
        sudoPending?.reply(.failure(SecureCard.Failure("Touch SD 退出了")))
        sudo.stop()
        ssh.server.stop()
        confirm.server.stop()
        finishGate(.failure(SecureCard.Failure("Touch SD 退出了")))
        card.shutdown()
    }

    // MARK: card

    var identity: SecureCard.Identity? {
        switch cardState {
        case .unpaired(let id), .paired(let id, _): return id
        default: return nil
        }
    }

    var pairedCard: PairedCard? {
        if case .paired(_, let p) = cardState { return p }
        return nil
    }

    private func cardChanged(_ s: CardState) {
        if case .paired = cardState, case .absent = s, lockOnRemove, !updating, resetStage == nil,
           Date() > noLockUntil {
            ScreenLock.now()
        }
        cardState = s
        switch s {
        case .paired(let id, _):
            openFingers(id.serial.hexString)
        case .unpaired where keepFingers:
            break
        default:
            keepFingers = false
            engine.lock { [weak self] in
                self?.fingerStore = .locked
                self?.refreshFingers()
            }
        }
        if case .paired(let id, _) = s {
            let k = "sshPublic." + id.serial.hexString
            let known = UserDefaults.standard.data(forKey: k)
            ssh.publicKey = known
            sshKey = known
            card.sshPublic { [weak self] r in
                guard let self, case .success(let pub) = r else { return }
                UserDefaults.standard.set(pub, forKey: k)
                self.ssh.publicKey = pub
                self.sshKey = pub
            }
        }
        if case .absent = s {
            touching = false
            if enroll != nil { show(.info, "卡被拔出了", "录入已暂停，插回卡后继续") }
        }
    }

    var statusLine: String {
        switch cardState {
        case .absent: return "没有插卡"
        case .outdated: return "固件需要升级"
        case .unpaired: return "卡未配对"
        case .paired(_, let p): return "已连接 · \(p.name)"
        case .failed(let e): return "连接出错：\(e)"
        }
    }

    // MARK: system authentication

    /// The Mac's own owner check (Touch ID or password) before anything that changes who
    /// or what the card unlocks.
    func authenticate(_ reason: String, _ then: @escaping () -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            alertText = "无法进行系统身份验证：\(err?.localizedDescription ?? "")"
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { if ok { then() } }
        }
    }

    // MARK: presses

    var purpose: Purpose {
        if sudoPending != nil { return .sudo }
        if gatePending != nil { return .gate }
        if let v = vaultWaiting { return v }
        if enroll != nil && enroll?.finished == nil { return .enroll }
        if pairing != nil { return .none }
        if actions.enabled || unlockTestVisible { return .unlock }
        return .none
    }

    func show(_ tone: Feedback.Tone, _ title: String, _ detail: String = "", hud showHUD: Bool = false) {
        let f = Feedback(tone: tone, title: title, detail: detail)
        feedback = f
        if showHUD || !NSApp.isActive { hud.flash(f) }
    }

    private func handle(_ p: Press) {
        let why = purpose
        if p.slid || why == .none { return }
        // the touch scrolled the page: a slide (the card publishes the frame of every touch)
        if slide.target != .volume && Date().timeIntervalSince(slide.lastScrollAt) < 1.0 && why == .unlock { return }
        if why == .enroll {
            engine.enrollTouch(p.raw) { [weak self] u in self?.enrollUpdate(u) }
            return
        }
        if UnlockGuard.blocked {
            show(.fail, "指纹已停用", "失败次数过多，请在 Touch SD 里输入 Mac 密码后重新启用", hud: true)
            return
        }
        engine.verify(p.raw) { [weak self] v in self?.verdict(v, press: p.press, purpose: why) }
    }

    private func verdict(_ v: FingerEngine.Verdict, press: UInt32, purpose why: Purpose) {
        switch v.kind {
        case .match:
            UnlockGuard.reset()
            accepted(press: press, finger: v.finger, fingerId: v.fingerId, purpose: why)
        case .nomatch:
            UnlockGuard.fail()
            show(.fail, "指纹不匹配", UnlockGuard.blocked ? "失败次数过多，指纹已停用" : "请重试", hud: why == .sudo || why == .gate)
            if why == .sudo {
                sudoFails += 1
                if sudoFails >= 3 { finishSudo(.failure(SecureCard.Failure("指纹不匹配"))) }
            }
            if why == .gate {
                gateFails += 1
                if gateFails >= 3 { finishGate(.failure(SecureCard.Failure("指纹不匹配"))) }
            }
        case .locked:
            show(.fail, "暂时锁定", v.message, hud: why == .sudo)
        default:
            show(.info, v.message, "", hud: why == .sudo)
        }
    }

    private func accepted(press: UInt32, finger: String?, fingerId: Int?, purpose why: Purpose) {
        let name = finger ?? ""
        switch why {
        case .sudo:
            guard let req = sudoPending else { return }
            card.sign(press: press, challenge: req.challenge) { [weak self] r in
                switch r {
                case .success(let sig):
                    self?.finishSudo(.success((press, sig)))
                    self?.show(.ok, "sudo 已授权", name, hud: true)
                case .failure(let e):
                    self?.show(.fail, "卡没有签名", "\(e)", hud: true)
                }
            }
        case .gate:
            guard let g = gatePending else { return }
            guard let digest = g.digest else {
                finishGate(.success(Data()))
                show(.ok, "已确认", name, hud: true)
                return
            }
            card.sshSign(press: press, digest: digest) { [weak self] r in
                self?.finishGate(r)
                if case .failure(let e) = r {
                    self?.show(.fail, "卡没有签名", "\(e)", hud: true)
                } else {
                    self?.show(.ok, "SSH 已签名", name, hud: true)
                }
            }
        case .vaultOpen, .vaultCreate, .vaultRewrap:
            let salt: Data
            if why == .vaultOpen, let s = vault.salt {
                salt = s
            } else {
                var s = Data(count: 32)
                s.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                salt = s
            }
            card.secret(press: press, salt: salt) { [weak self] r in
                guard let self else { return }
                self.vaultWaiting = nil
                do {
                    let secret = try r.get()
                    let serial = self.identity?.serial ?? Data()
                    switch why {
                    case .vaultCreate: try self.vault.create(cardSecret: secret, salt: salt, serial: serial)
                    case .vaultRewrap: try self.vault.rewrap(cardSecret: secret, salt: salt, serial: serial)
                    default: try self.vault.open(cardSecret: secret)
                    }
                    self.show(.ok, why == .vaultOpen ? "保险箱已打开" : "保险箱已保护", name)
                } catch {
                    self.show(.fail, "保险箱", "\(error)")
                }
            }
        case .unlock:
            show(.ok, "已识别", name, hud: true)
            if actions.needsVault(fingerId: fingerId), vault.state != .open, let salt = vault.salt {
                card.secret(press: press, salt: salt) { [weak self] r in
                    guard let self else { return }
                    do { try self.vault.open(cardSecret: r.get()) } catch { self.show(.fail, "保险箱", "\(error)", hud: true) }
                    self.actions.run(finger: finger, fingerId: fingerId)
                }
            } else {
                actions.run(finger: finger, fingerId: fingerId)
            }
        default:
            break
        }
    }

    // MARK: pairing

    func startPairing() {
        authenticate("配对一张新的指纹卡") { [weak self] in
            guard let self else { return }
            self.pairing = PairingFlow()
            self.card.beginPairing { [weak self] r in
                switch r {
                case .success(let p):
                    self?.pairing = PairingFlow(step: .compare, colors: p.colors, cardKey: p.card.fingerprint, pairing: p)
                case .failure(let e):
                    self?.pairing?.step = .failed("\(e)")
                }
            }
        }
    }

    /// The user says the colours match: keep confirming until the card has seen a press.
    func colorsMatch() {
        guard let p = pairing?.pairing else { return }
        pairing?.step = .waitingPress
        let name = Host.current().localizedName ?? "这台 Mac"
        func again(_ left: Int) {
            card.confirmPairing(p, name: name) { [weak self] r in
                guard let self, self.pairing != nil else { return }
                switch r {
                case .success(true):
                    self.pairing?.step = .done
                case .success(false) where left > 0:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { again(left - 1) }
                case .success(false):
                    self.pairing?.step = .failed("没有等到传感器上的按压，请重新配对")
                case .failure(let e):
                    self.pairing?.step = .failed("\(e)")
                }
            }
        }
        again(300)
    }

    func cancelPairing() {
        if case .done = pairing?.step {} else { card.cancelPairing() }
        pairing = nil
    }

    func unpair() {
        authenticate("解除这张卡和这台 Mac 的配对") { [weak self] in
            self?.keepFingers = true
            self?.card.unpair { r in
                if case .failure(let e) = r { self?.alertText = "\(e)" }
            }
        }
    }

    func factoryReset() {
        authenticate("恢复这张卡的出厂设置") { [weak self] in
            self?.resetStage = .waiting
            self?.card.factoryReset(onHold: { self?.resetStage = $0 ? .holding : .waiting }) { r in
                guard let self else { return }
                self.resetStage = nil
                switch r {
                case .success(true):
                    self.keepFingers = true
                    self.alertText = "卡已恢复出厂设置。现在重新配对，已录的指纹会继续可用；如果先退出 App，就要重新录入。"
                case .success(false):
                    if !self.card.resetCancelled { self.alertText = "30 秒内没有按住传感器，卡没有变化。" }
                case .failure(let e):
                    self.alertText = "\(e)"
                }
            }
        }
    }

    func forgetCards() {
        authenticate("忘记所有配对过的卡") { [weak self] in
            for c in PairedCard.all() { self?.card.forget(c) }
        }
    }

    // MARK: fingers

    private func openFingers(_ serial: String, discard: Bool = false) {
        engine.salt(card: serial) { [weak self] salt in
            self?.card.storeSecret(salt: salt) { r in
                guard let self else { return }
                guard case .success(let secret) = r else { return }
                let done: (FingerEngine.StoreState) -> Void = { st in
                    self.keepFingers = false
                    self.fingerStore = st
                    self.refreshFingers()
                }
                if discard {
                    self.engine.discardStore(card: serial, salt: salt, secret: secret, done)
                } else {
                    self.engine.unlock(card: serial, salt: salt, secret: secret, done)
                }
            }
        }
    }

    /// This card cannot open the fingers file (reset or unpaired since): start over.
    func discardFingers() {
        guard let id = identity else { return }
        authenticate("删除旧的指纹库，重新录入") { [weak self] in
            self?.openFingers(id.serial.hexString, discard: true)
        }
    }

    func refreshFingers() {
        engine.fingers { [weak self] list in self?.fingers = list }
    }

    func startEnroll() {
        guard fingers.count < engine.maxFingers else {
            alertText = "最多录入 \(engine.maxFingers) 个指纹"
            return
        }
        authenticate("录入新的指纹") { [weak self] in
            guard let self else { return }
            self.engine.startEnroll()
            self.enroll = EnrollFlow(steps: self.engine.enrollSteps)
        }
    }

    func cancelEnroll() {
        engine.cancelEnroll()
        enroll = nil
    }

    private func enrollUpdate(_ u: FingerEngine.EnrollUpdate) {
        guard enroll != nil else { return }
        enroll?.done = u.done
        enroll?.steps = u.steps
        enroll?.title = u.stage.title
        enroll?.detail = u.stage.description
        if let m = u.mosaic { enroll?.mosaic = m }
        switch u.kind {
        case .help:
            enroll?.hint = u.message
            enroll?.hintIsProblem = true
        case .done:
            enroll?.hint = u.message
            enroll?.hintIsProblem = false
            enroll?.finished = u.finger
            refreshFingers()
        default:
            enroll?.hint = u.message
            enroll?.hintIsProblem = false
        }
    }

    func rename(_ id: Int, _ name: String) {
        engine.rename(id, name) { [weak self] in self?.refreshFingers() }
    }

    func delete(_ id: Int) {
        authenticate("删除指纹") { [weak self] in
            self?.engine.delete(id) { self?.refreshFingers() }
        }
    }

    func importPlain() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择开发工具的 fpdb 文件夹（里面有 fingers.json）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        authenticate("导入指纹") { [weak self] in
            self?.engine.importPlain(url) { n in
                self?.refreshFingers()
                self?.alertText = "导入了 \(n) 个指纹。原文件夹是明文的，确认不再需要后请自行删除。"
            }
        }
    }

    func resetFailures() {
        authenticate("重新启用指纹") { [weak self] in
            UnlockGuard.reset()
            self?.engine.resetLockout()
            self?.objectWillChange.send()
        }
    }

    // MARK: vault

    func requestVault(_ p: Purpose) {
        guard pairedCard != nil else {
            alertText = "先插入并配对指纹卡"
            return
        }
        guard !fingers.isEmpty else {
            alertText = "先录入至少一个指纹"
            return
        }
        vaultWaiting = p
        show(.info, "请按指纹", p == .vaultCreate ? "创建保险箱" : "打开保险箱")
    }

    func cancelVaultWait() { vaultWaiting = nil }

    // MARK: sudo

    private func sudoRequest(_ r: SudoBridge.Request) {
        guard pairedCard != nil, !fingers.isEmpty else {
            r.reply(.failure(SecureCard.Failure("卡没有连上或没有录入指纹")))
            return
        }
        guard !UnlockGuard.blocked else {
            r.reply(.failure(SecureCard.Failure("指纹已停用")))
            return
        }
        sudoPending?.reply(.failure(SecureCard.Failure("有新的请求")))
        sudoPending = r
        sudoFails = 0
        hud.showSudo(user: r.user) { [weak self] in self?.finishSudo(.failure(SecureCard.Failure("已取消"))) }
        sudoTimer?.invalidate()
        sudoTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishSudo(.failure(SecureCard.Failure("超时"))) }
        }
    }

    private func gateRequest(_ g: Gate) {
        guard pairedCard != nil, !fingers.isEmpty else {
            g.reply(.failure(SecureCard.Failure("卡没有连上或没有录入指纹")))
            return
        }
        guard !UnlockGuard.blocked else {
            g.reply(.failure(SecureCard.Failure("指纹已停用")))
            return
        }
        guard gatePending == nil, sudoPending == nil else {
            g.reply(.failure(SecureCard.Failure("正在等另一个请求")))
            return
        }
        gatePending = g
        gateFails = 0
        hud.showPrompt(title: g.title, detail: g.detail) { [weak self] in
            self?.finishGate(.failure(SecureCard.Failure("已取消")))
        }
        gateTimer?.invalidate()
        gateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishGate(.failure(SecureCard.Failure("超时"))) }
        }
    }

    private func finishGate(_ r: Result<Data, Error>) {
        gateTimer?.invalidate()
        gatePending?.reply(r)
        gatePending = nil
        hud.hideSudo()
    }

    private func finishSudo(_ r: Result<(UInt32, Data), Error>) {
        sudoTimer?.invalidate()
        sudoPending?.reply(r)
        sudoPending = nil
        hud.hideSudo()
    }

    func installSudo() {
        guard let card = pairedCard else {
            alertText = "先插入并配对指纹卡"
            return
        }
        guard let module = Bundle.main.url(forResource: "pam_sdfinger", withExtension: "so.2") else {
            alertText = "App 里没有找到 pam_sdfinger 模块（用 scripts/build_app.sh 构建的 .app 才带）"
            return
        }
        do {
            try SudoBridge.install(card: card, module: module)
        } catch {
            alertText = "\(error)"
        }
        sudoInstalled = SudoBridge.installed
    }

    func uninstallSudo() {
        do { try SudoBridge.uninstall() } catch { alertText = "\(error)" }
        sudoInstalled = SudoBridge.installed
    }

    // MARK: login item

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alertText = "设置开机启动失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: firmware

    func runUpdate(_ url: URL) {
        let pkg: UpdatePackage
        do { pkg = try UpdatePackage(url: url) } catch {
            alertText = "\(error)"
            return
        }
        updating = true
        updateLog = ["更新包：固件 \(pkg.firmware)，镜像 \(pkg.image)"]
        card.pause { [weak self] in
            DispatchQueue.global().async {
                let r = Result {
                    try Updater.run(pkg, volume: CardMailbox.volume) { line in
                        DispatchQueue.main.async { self?.updateLog.append(line) }
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch r {
                    case .success(let head): self.updateLog.append("完成：\(head)")
                    case .failure(let e): self.updateLog.append("失败：\(e)")
                    }
                    self.updating = false
                    self.card.resume()
                }
            }
        }
    }
}
