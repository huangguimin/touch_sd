@preconcurrency import FingerCore
import FingerUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: vault

struct VaultPage: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var vault: Vault
    @State private var editing: VaultItem?
    @State private var search = ""
    @State private var recovering = false
    @State private var recoveryText = ""
    @State private var reveal: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "保险箱", subtitle: "存密码、密钥之类的东西。打开要同时满足：这台 Mac、配对的卡插着、真的按了传感器、按的是录入过的手指。")
            switch vault.state {
            case .none: createPanel
            case .locked: lockedPanel
            case .open: openPanel
            }
        }
        .sheet(item: $editing) { item in ItemEditor(item: item) { editing = nil } }
        .sheet(isPresented: Binding(get: { vault.recoveryKeyToShow != nil }, set: { if !$0 { vault.recoveryKeyToShow = nil } })) {
            RecoverySheet(key: vault.recoveryKeyToShow ?? "") { vault.recoveryKeyToShow = nil }
        }
        .sheet(isPresented: $recovering) {
            VStack(alignment: .leading, spacing: 12) {
                Text("用恢复密钥打开").font(.headline)
                Text("卡丢了或换了卡时用。打开后请按指纹，用现在的卡重新保护。").foregroundStyle(.secondary)
                TextField("XXXXXXX-XXXXXXX-…", text: $recoveryText).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                HStack {
                    Spacer()
                    Button("取消") { recovering = false }
                    Button("打开") {
                        do {
                            try vault.open(recovery: recoveryText)
                            recovering = false
                            recoveryText = ""
                        } catch { app.alertText = "\(error)" }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 520)
        }
    }

    private var waiting: Bool { app.vaultWaiting != nil }

    private var createPanel: some View {
        Panel {
            HStack(spacing: 16) {
                TouchGlyph(active: app.touching, size: 46, waiting: waiting)
                VStack(alignment: .leading, spacing: 6) {
                    Text(waiting ? "请按指纹" : "还没有保险箱").font(.headline)
                    Text("创建时会生成一把随机的保险箱密钥，用卡和这台 Mac 一起保护起来，并给你一个恢复密钥抄下来备用。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if waiting {
                    Button("取消") { app.cancelVaultWait() }
                } else {
                    Button("创建保险箱") { app.requestVault(.vaultCreate) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var lockedPanel: some View {
        Panel {
            HStack(spacing: 16) {
                TouchGlyph(active: app.touching, size: 46, waiting: waiting)
                VStack(alignment: .leading, spacing: 6) {
                    Text(waiting ? "请在卡上按指纹" : "保险箱已上锁").font(.headline)
                    FeedbackLine(feedback: waiting ? app.feedback : nil)
                }
                Spacer()
                if waiting {
                    Button("取消") { app.cancelVaultWait() }
                } else {
                    Button("用恢复密钥…") { recovering = true }
                    Button("按指纹打开") { app.requestVault(.vaultOpen) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var openPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("搜索", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button {
                    editing = VaultItem(title: "", account: "", secret: "", note: "")
                } label: { Label("添加", systemImage: "plus") }
                Button {
                    vault.lock()
                } label: { Label("锁上", systemImage: "lock") }
                .buttonStyle(.borderedProminent)
            }
            Panel {
                let list = vault.items.filter {
                    search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                        $0.account.localizedCaseInsensitiveContains(search)
                }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
                if list.isEmpty {
                    Text(vault.items.isEmpty ? "保险箱是空的，点“添加”放点东西进去。" : "没有匹配的条目").foregroundStyle(.secondary)
                }
                ForEach(list) { it in
                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.title.isEmpty ? "（无标题）" : it.title).font(.headline)
                            Text(reveal == it.id ? it.secret : (it.account.isEmpty ? "••••••••" : it.account))
                                .font(.system(.callout, design: reveal == it.id ? .monospaced : .default))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if let t = it.code {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                HStack(spacing: 6) {
                                    Text(t.code(at: ctx.date)).font(.system(.body, design: .monospaced))
                                    Text("\(t.secondsLeft(at: ctx.date))s").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button { vault.copy(t.code()) } label: { Image(systemName: "number") }
                                .help("复制验证码")
                        }
                        Button { reveal = reveal == it.id ? nil : it.id; vault.touch() } label: {
                            Image(systemName: reveal == it.id ? "eye.slash" : "eye")
                        }
                        .help("显示")
                        Button { vault.copy(it.secret) } label: { Image(systemName: "doc.on.doc") }
                            .help("复制密码（60 秒后自动清除剪贴板）")
                        Button { editing = it } label: { Image(systemName: "pencil") }
                        Button(role: .destructive) { try? vault.remove(it.id) } label: { Image(systemName: "trash") }
                    }
                    if it != list.last { Divider() }
                }
            }
            HStack {
                Text("2 分钟不操作、合上屏幕或锁屏时自动上锁。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("换卡后重新保护") { app.requestVault(.vaultRewrap) }
                    .help("用现在插着的卡重新保护保险箱密钥（用恢复密钥打开之后用）")
            }
        }
    }
}

struct ItemEditor: View {
    @EnvironmentObject var vault: Vault
    @EnvironmentObject var app: AppState
    @State var item: VaultItem
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title.isEmpty ? "新条目" : item.title).font(.headline)
            Form {
                TextField("标题", text: $item.title)
                TextField("账号", text: $item.account)
                SecureField("密码 / 密钥", text: $item.secret)
                SecureField("两步验证密钥（可选）", text: Binding(get: { item.totp ?? "" },
                                                        set: { item.totp = $0.isEmpty ? nil : $0 }))
                if let t = item.totp, TOTP(t) == nil {
                    Text("不是有效的 Base32 密钥或 otpauth:// 链接").font(.caption).foregroundStyle(.orange)
                }
                TextField("备注", text: $item.note, axis: .vertical).lineLimit(3...6)
            }
            HStack {
                Spacer()
                Button("取消", action: done)
                Button("保存") {
                    do { try vault.upsert(item) } catch { app.alertText = "\(error)" }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct RecoverySheet: View {
    let key: String
    let done: () -> Void
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("恢复密钥", systemImage: "key.viewfinder").font(.title3.bold())
            Text("卡丢了、换了 Mac 或钥匙串被清掉时，只有这串字符能打开保险箱。抄在纸上收好，不要存在这台 Mac 上。它只显示这一次。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(key)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Toggle("我已经抄下来了", isOn: $saved)
            HStack {
                Spacer()
                Button("完成", action: done).disabled(!saved).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}

// MARK: actions

struct ActionsPage: View {
    @EnvironmentObject var actions: Actions
    @EnvironmentObject var app: AppState
    @EnvironmentObject var vault: Vault

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "解锁动作", subtitle: "打开后，每次按指纹识别通过，就按顺序执行下面的动作。每个动作可以指定由哪根手指触发。滑动手指不算按压。")
            Panel {
                Toggle(isOn: $actions.enabled) {
                    VStack(alignment: .leading) {
                        Text("按指纹时执行").font(.headline)
                        Text("关着的时候，按压不会触发识别，也不会计入失败次数。").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .toggleStyle(.switch)
            }
            Panel(title: "动作") {
                ForEach($actions.list) { $a in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $a.enabled).labelsHidden()
                        Picker("", selection: $a.kind) {
                            ForEach(UnlockAction.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        if a.kind == .app {
                            AppField(path: $a.value)
                        } else if a.kind.holdsText {
                            TextEntry(action: a)
                        } else if a.kind == .totp {
                            if vault.state == .open {
                                Picker("", selection: Binding(get: { a.value }, set: { v in
                                    a.value = v
                                    a.title = vault.items.first { $0.id.uuidString == v }?.title
                                    if !KeySender.trusted { KeySender.requestTrust() }
                                })) {
                                    Text("选择条目").tag("")
                                    ForEach(vault.items.filter { $0.code != nil }) { Text($0.title).tag($0.id.uuidString) }
                                }
                                .labelsHidden()
                            } else {
                                Text(a.title ?? "打开保险箱后选择条目").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            TextField(a.kind.placeholder, text: $a.value).textFieldStyle(.roundedBorder)
                        }
                        Picker("", selection: $a.fingerId) {
                            Text("任意指纹").tag(Int?.none)
                            ForEach(app.fingers) { Text($0.name).tag(Int?.some($0.id)) }
                            if let id = a.fingerId, !app.fingers.contains(where: { $0.id == id }) {
                                Text("已删除的指纹").tag(Int?.some(id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button(role: .destructive) {
                            actions.remove(a)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                    if a.kind.holdsText {
                        HStack(spacing: 16) {
                            Toggle("输完按回车", isOn: Binding(get: { a.pressesEnter }, set: { a.enter = $0 }))
                            if a.kind == .login {
                                Text("只在锁屏界面输入，其他时候不会触发").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("每次识别都会输入到当前窗口，锁屏时不输入").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 44)
                    }
                }
                Button {
                    actions.list.append(UnlockAction(kind: .app, value: ""))
                } label: { Label("添加动作", systemImage: "plus") }
                if !actions.lastRun.isEmpty {
                    Text("上次执行：\(actions.lastRun)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("同一根手指可以绑多个动作，比如中指：打开几个工作应用，再运行一个开勿扰的快捷指令。验证码会输入到当前光标所在的输入框，保险箱锁着时这一按会先打开它。登录密码只在锁屏界面输入，要输入到其他窗口的内容用“自动键入文字”。shell 命令以你的身份运行，环境变量 SD_FINGER_FINGER 是识别到的指纹名。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The text of an action: written here, kept in the keychain, never shown again.
struct TextEntry: View {
    @EnvironmentObject var actions: Actions
    let action: UnlockAction
    @State private var text = ""

    var body: some View {
        SecureField(action.value.isEmpty ? (action.kind == .login ? "这台 Mac 的登录密码" : "要键入的文字") : "已保存，输入新内容可替换", text: $text)
            .textFieldStyle(.roundedBorder)
            .onChange(of: text) { t in
                if t.count > Actions.maxText { text = String(t.prefix(Actions.maxText)) }
            }
            .onSubmit { save() }
            .onDisappear { save() }
    }

    private func save() {
        guard !text.isEmpty else { return }
        actions.setText(text, for: action.id)
        text = ""
        if !KeySender.trusted { KeySender.requestTrust() }
    }
}

// MARK: SSH and confirmation

struct DeveloperPage: View {
    @EnvironmentObject var app: AppState

    private var sock: String { "\"$HOME/Library/Application Support/SD Finger/ssh.sock\"" }
    private var tool: String { Bundle.main.url(forResource: "fingerconfirm", withExtension: nil)?.path ?? "fingerconfirm" }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
            }
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "SSH 与确认", subtitle: "SSH 密钥在卡里，取不出来，每次签名都要按一下录入的手指。")
            Panel(title: "SSH 和 Git") {
                Toggle("启用 SSH Agent", isOn: $app.sshEnabled)
                if let key = app.sshKey {
                    let auth = SSHAgent.authorizedKey(key)
                    snippet("公钥：加到 GitHub 或服务器的 authorized_keys", auth)
                    snippet("~/.zshrc：让 ssh 和 git 都用这个 Agent", "export SSH_AUTH_SOCK=\(sock)")
                    snippet("Git 提交签名", "git config --global gpg.format ssh\ngit config --global user.signingkey \"key::\(auth)\"\ngit config --global commit.gpgsign true")
                } else {
                    Text("连上已配对的卡后这里会显示公钥。").foregroundStyle(.secondary)
                }
                Text("这把密钥属于“这张卡 + 这台 Mac”的配对：解除配对或恢复出厂后就没了，重新配对会得到新的公钥。卡限制每分钟最多 5 次签名，给很多提交一次性签名时会被挡住。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Panel(title: "高危操作确认") {
                Text("脚本在做危险的事之前要求按指纹。这是防手滑，不是防入侵：能以你的身份运行程序的人也能绕过脚本。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                snippet("用法", "\(tool.contains(" ") ? "\"\(tool)\"" : tool) \"删除生产库\" && ./drop_prod.sh")
            }
        }
    }
}

// MARK: sudo

struct SudoPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "sudo", subtitle: "在终端里用 sudo 时，可以按指纹卡代替输入密码。卡不在、App 没开或者识别不通过时，sudo 照常问密码。")
            Panel {
                HStack(spacing: 14) {
                    Image(systemName: app.sudoInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.title).foregroundStyle(app.sudoInstalled ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.sudoInstalled ? "已启用" : "未启用").font(.headline)
                        Text(app.sudoInstalled ? "在终端运行 sudo 时，屏幕上方会出现提示，按一下指纹就行。" :
                                "安装需要管理员密码：会装一个 PAM 模块，并在 /etc/pam.d/sudo_local 加一行。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if app.sudoInstalled {
                        Button("停用") { app.uninstallSudo() }
                    } else {
                        Button("启用") { app.installSudo() }
                            .buttonStyle(.borderedProminent)
                            .disabled(app.pairedCard == nil || app.fingers.isEmpty)
                    }
                }
                if !app.sudoInstalled && (app.pairedCard == nil || app.fingers.isEmpty) {
                    Text("需要先配对卡并录入指纹。").font(.caption).foregroundStyle(.orange)
                }
                if #unavailable(macOS 14) {
                    Text("需要 macOS 14 或更新（sudo_local）。").font(.caption).foregroundStyle(.orange)
                }
            }
            Panel(title: "怎么保证安全") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("sudo 里的模块每次生成新的随机挑战，卡用自己的私钥对“挑战 + 这一次按压”签名，模块用安装时记下的卡公钥验证。录下来的回答不能重放。")
                    bullet("卡只在真的有人按了传感器之后才签名，每分钟最多 5 次。")
                    bullet("比对指纹是在 App 里做的：如果有恶意程序以你的身份运行并篡改 App，它仍然需要你的卡和一次真实的按压，但能跳过“是不是你的手指”这一步。对高风险的机器，请保留密码。")
                    bullet("换了卡要重新点“启用”，把新卡的公钥装进去。")
                }
            }
            Text("测试：在终端运行  sudo -k && sudo true").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: slide

struct SlidePage: View {
    @EnvironmentObject var s: SlideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "滑动控制", subtitle: "手指沿传感器的长边滑动：调音量，或者滚动浏览器里的页面。位移由卡上的固件计算。")
            Panel {
                Picker("滑动用来", selection: $s.target) {
                    ForEach(SlideModel.Target.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 560)
                SlideCanvas().frame(height: 300)
                Text(s.info).font(.caption).foregroundStyle(.secondary)
            }
            if s.target == .volume {
                Panel(title: "音量") {
                    Toggle("滑动时调节 Mac 的音量", isOn: $s.driveSystem)
                    HStack {
                        Text("灵敏度")
                        Slider(value: $s.rowsPerPercent, in: 2...30) { Text("") } minimumValueLabel: { Text("快") } maximumValueLabel: { Text("慢") }
                            .frame(width: 260)
                        Text("每 \(Int(s.rowsPerPercent)) 行 1%").foregroundStyle(.secondary)
                    }
                }
            } else if s.target.isKeys {
                Panel(title: s.target.label) {
                    if !s.scrollTrusted {
                        HStack {
                            Label("需要“辅助功能”权限才能发送按键", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("我已打开") { s.refreshTrust() }
                        }
                    }
                    Text(s.target.hint).foregroundStyle(.secondary)
                }
            } else {
                Panel(title: "页面滚动") {
                    if !s.scrollTrusted {
                        HStack {
                            Label("需要“辅助功能”权限才能滚动其他 App 的页面", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("打开设置…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Button("我已打开") { s.refreshTrust() }
                        }
                    }
                    Toggle("只在浏览器里滚动（Safari、Chrome、Edge、Firefox、Arc……）", isOn: $s.browserOnly)
                    Toggle("碰一下传感器，把焦点还给鼠标下面的窗口", isOn: $s.refocusOnTouch)
                    HStack {
                        Text("滚动速度")
                        Slider(value: $s.pixelsPerRow, in: 0.5...24) { Text("") } minimumValueLabel: { Text("慢") } maximumValueLabel: { Text("快") }
                            .frame(width: 260)
                        Text("滑满一次约 \(Int(s.pixelsPerRow * Double(SlideModel.rows))) 像素").foregroundStyle(.secondary)
                    }
                    Text("滚动发给鼠标指针下面的窗口，和触控板的平滑滚动一样。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel(title: "手感") {
                Toggle("方向反过来", isOn: $s.invert)
                HStack {
                    Toggle("滑动音效", isOn: $s.soundOn)
                    Picker("", selection: $s.soundStyle) {
                        ForEach(SlideModel.SoundStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170).disabled(!s.soundOn)
                    Slider(value: $s.soundVolume, in: 0...1).frame(width: 140).disabled(!s.soundOn)
                }
            }
        }
        .onAppear { s.refreshTrust() }
    }
}

// MARK: device

struct DevicePage: View {
    @EnvironmentObject var app: AppState
    @State private var status = ""
    @State private var info: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "设备", subtitle: "卡的身份、固件和配对。")
            Panel(title: "这张卡") {
                if let id = app.identity {
                    InfoRow(label: "身份指纹", value: id.fingerprint)
                    InfoRow(label: "序列号", value: id.serialHex)
                    InfoRow(label: "配对位置", value: "已用 \(id.slotsUsed) / \(id.slots)")
                    InfoRow(label: "固件类型", value: id.developmentImage ? "开发版（未建立会话时会输出明文图像）" : "正式版")
                }
                ForEach(info.filter { ["fw", "image", "built", "board"].contains($0.0) }, id: \.0) { kv in
                    InfoRow(label: ["fw": "固件版本", "image": "镜像版本", "built": "构建时间", "board": "板子"][kv.0] ?? kv.0,
                            value: kv.1)
                }
                if app.identity == nil { Text("没有连接卡").foregroundStyle(.secondary) }
                HStack {
                    Button("刷新") { refresh() }
                    Spacer()
                    if app.pairedCard != nil {
                        Button("解除配对", role: .destructive) { app.unpair() }
                    }
                }
            }
            Panel(title: "固件升级") {
                Text("把 UPDATE.BIN 写到卡上，卡会自己装到另一个分区再重启，不用拔卡。版本必须比卡上的新。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(app.updating ? "升级中…" : "选择 UPDATE.BIN 并升级…") { chooseUpdate() }
                        .disabled(app.updating || app.identity == nil && !FileManager.default.fileExists(atPath: CardMailbox.volume))
                    if app.updating { ProgressView().controlSize(.small) }
                }
                if !app.updateLog.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(app.updateLog.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
            LEDPanel(leds: app.leds)
            Panel(title: "恢复出厂") {
                Text("清空卡上的所有配对，换一个新的卡身份。卡转手前做一次，新主人就和拿到新卡一样。指纹库绑定这张卡的密钥：恢复出厂后立刻在这台 Mac 重新配对，指纹继续可用，否则要重新录入；保险箱要用恢复密钥才能打开。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let stage = app.resetStage {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(stage == .waiting ? "把手指放到传感器上按住，灯闪得快了就保持不动，约 5 秒。" : "保持按住，直到灯变红……")
                    }
                }
                HStack {
                    if app.resetStage == nil {
                        Button("恢复出厂…") { app.factoryReset() }
                            .disabled(!FileManager.default.fileExists(atPath: CardMailbox.volume))
                    } else {
                        Button("取消") { app.card.cancelFactoryReset() }
                    }
                    Spacer()
                    Button("在这台 Mac 上忘记所有卡…") { app.forgetCards() }
                }
            }
            Panel(title: "离开时") {
                Toggle("拔出卡时锁定屏幕", isOn: $app.lockOnRemove)
                Text("只在卡已连接时生效；升级固件、恢复出厂和 Mac 睡眠时不会触发。").font(.caption).foregroundStyle(.secondary)
            }
            Panel(title: "App") {
                Toggle("在程序坞显示图标", isOn: $app.showDockIcon)
                Toggle("登录时启动", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                Text("关掉窗口后 App 仍在菜单栏运行，解锁动作和 sudo 才能用。").font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Panel(title: "运行状态（STATUS.TXT）") {
                    Text(status).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        info = CardFiles.info(volume: CardMailbox.volume)
        app.card.statusText { r in status = (try? r.get()) ?? CardFiles.status(volume: CardMailbox.volume) }
    }

    private func chooseUpdate() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "BIN") ?? .data, .data]
        p.message = "选择固件更新包 UPDATE.BIN"
        guard p.runModal() == .OK, let url = p.url else { return }
        app.runUpdate(url)
    }
}

// MARK: security

struct SecurityPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "安全说明", subtitle: "Touch SD 能防住什么、防不住什么。完整设计见 docs/SECURITY_DESIGN.md。")
            if let id = app.identity {
                Panel(title: "这张卡现在的状态") {
                    if id.developmentImage {
                        Label("开发版固件：没有建立加密会话时，卡会在卷上输出明文指纹图像（给开发工具用）。正式版固件不会。",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    // sealed without secure boot means the development key: it hides nothing
                    state(id.keysSealed && id.secureBoot, "配对密钥用这颗芯片专属的密钥加密存放",
                          "配对密钥没有受芯片保护，拿到实物的人有可能读出来")
                    state(id.secureBoot, "安全启动已开启：卡只运行签名的固件，固件在闪存里是加密的",
                          "安全启动没有开启：卡能运行任何固件")
                    state(id.debugDisabled, "调试接口已永久关闭", "调试接口没有关闭")
                }
            }
            Panel(title: "能防住") {
                row("其他程序读 SD 卷偷指纹", "配对后卡和 App 之间的每条消息、每一帧指纹都用 ChaCha20-Poly1305 加密认证，密钥每次会话不同。")
                row("录下通信再重放、篡改", "每个方向的计数器只增不减，认证不过的消息直接丢弃。")
                row("冒充的卡", "配对时卡用自己的身份密钥签名，并在灯上显示颜色让你核对，中间人一次猜中的概率约 170 万分之一。")
                row("偷走 Mac（没带卡）", "保险箱要卡算出的秘密才能打开；指纹模板用钥匙串里的密钥加密。")
                row("暴力试指纹", "不显示分数；App 连续失败锁定、累计失败停用；卡上每分钟最多 5 次。")
            }
            Panel(title: "防不住") {
                row("Mac 已被完全控制", "有 root 权限的恶意软件可以读取 App 的内存和钥匙串。")
                row("卡、已登录的 Mac 和改过的 App 同时在攻击者手里", "比对在 App 里做，这种情况下可以跳过比对。以后把比对移到卡上才能补上。")
                row("假手指", "没有活体检测。")
                row("对芯片的物理攻击", "消费级的防护，不是银行级。")
            }
        }
    }

    private func state(_ ok: Bool, _ good: String, _ bad: String) -> some View {
        Label(ok ? good : bad, systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ a: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a).bold()
            Text(b).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
