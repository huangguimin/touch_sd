@preconcurrency import FingerCore
import FingerUI
import SwiftUI

// MARK: home

struct HomePage: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var vault: Vault
    @EnvironmentObject var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Touch SD", subtitle: "插在 Mac 卡槽里的指纹卡：解锁保险箱、终端 sudo、按指纹执行动作，手指滑动还能调音量。")
            hero
            if app.pairedCard != nil {
                tryIt
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    tile("touchid", "指纹", app.fingerStore == .open ? (app.fingers.isEmpty ? "还没有录入" : "已录入 \(app.fingers.count) 个") : "插卡后解开", .fingers)
                    tile("lock.rectangle.stack", "保险箱",
                         vault.state == .none ? "未创建" : vault.state == .open ? "已打开" : "已上锁", .vault)
                    tile("bolt", "解锁动作", actions.enabled ? "已开启 · \(actions.list.count) 个动作" : "已关闭", .actions)
                    tile("terminal", "sudo", app.sudoInstalled ? "已启用指纹" : "未启用", .sudo)
                }
            }
        }
        .onAppear { app.unlockTestVisible = true }
        .onDisappear { app.unlockTestVisible = false }
    }

    @ViewBuilder private var hero: some View {
        Panel {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(app.pairedCard != nil ? Color.accentColor : .secondary)
                    .frame(width: 60)
                VStack(alignment: .leading, spacing: 8) {
                    switch app.cardState {
                    case .absent:
                        Text("插入指纹卡").font(.title3.bold())
                        Text("把 Touch SD 卡插进 Mac 的 SD 卡槽。卡出现后会自动连接。").foregroundStyle(.secondary)
                    case .outdated(let why):
                        Text("卡上的固件太旧").font(.title3.bold())
                        Text(why).foregroundStyle(.secondary)
                        Button("去升级固件") { app.page = .device }
                    case .unpaired(let id):
                        Text("新的指纹卡").font(.title3.bold())
                        Text("这张卡（\(id.fingerprint)）还没有和这台 Mac 配对。配对时卡上的灯会闪一串颜色，和屏幕上对一下，再按一下传感器就好。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if id.slotsUsed >= id.slots {
                            Text("卡上的 \(id.slots) 个配对位置都用完了：到“设备”页恢复出厂可以清空。")
                                .foregroundStyle(.orange)
                        }
                        Button("开始配对") { app.startPairing() }
                            .buttonStyle(.borderedProminent)
                    case .paired(let id, let p):
                        Text(p.name.isEmpty ? "指纹卡" : "已连接").font(.title3.bold())
                        HStack(spacing: 8) {
                            Chip(text: "加密会话", symbol: "lock.fill", color: .green)
                            Chip(text: "卡 \(id.fingerprint)", symbol: "key.fill", color: .secondary)
                            if id.developmentImage {
                                Chip(text: "开发版固件", symbol: "exclamationmark.triangle.fill", color: .orange)
                            }
                        }
                    case .failed(let e):
                        Text("连接出错").font(.title3.bold())
                        Text(e).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var tryIt: some View {
        Panel {
            HStack(spacing: 18) {
                TouchGlyph(active: app.touching, size: 52)
                VStack(alignment: .leading, spacing: 6) {
                    if app.fingers.isEmpty {
                        Text("录入第一个指纹").font(.headline)
                        Text("录入大约需要按 30 次，每次稍微挪一挪位置。").foregroundStyle(.secondary)
                        Button("添加指纹") { app.startEnroll() }.buttonStyle(.borderedProminent)
                    } else if UnlockGuard.blocked {
                        Text("指纹已停用").font(.headline)
                        Text("连续失败太多次，需要验证 Mac 密码后才能继续使用。").foregroundStyle(.secondary)
                        Button("重新启用") { app.resetFailures() }
                    } else {
                        Text("按一下传感器试试").font(.headline)
                        FeedbackLine(feedback: app.feedback)
                            .animation(.default, value: app.feedback)
                        if app.feedback == nil {
                            Text("这个页面打开时，每次按压都会识别一次。").foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ value: String, _ page: Page) -> some View {
        Button { app.page = page } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(value).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: pairing

struct PairingSheet: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 20) {
            switch app.pairing?.step ?? .starting {
            case .starting:
                ProgressView()
                Text("正在和卡交换密钥……")
            case .compare:
                Text("核对颜色").font(.title2.bold())
                Text("卡上的两颗灯正在一起闪一串颜色，8 个一组，组与组之间会暗一下。和下面的顺序一样吗？")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                colors
                Text("卡的身份：\(app.pairing?.cardKey ?? "")").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("不一样") { app.cancelPairing() }
                    Button("一样") { app.colorsMatch() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .waitingPress:
                TouchGlyph(active: app.touching, size: 70, waiting: true)
                Text("在卡的传感器上按一下").font(.title2.bold())
                Text("这一下是告诉卡：颜色核对过了。").foregroundStyle(.secondary)
                Button("取消") { app.cancelPairing() }
            case .done:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green)
                Text("配对完成").font(.title2.bold())
                Text("这台 Mac 和这张卡之间的通信从现在起全部加密。").foregroundStyle(.secondary)
                HStack {
                    Button("完成") { app.pairing = nil }
                    if app.fingers.isEmpty {
                        Button("录入第一个指纹") {
                            app.pairing = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.startEnroll() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(.orange)
                Text("配对没有完成").font(.title2.bold())
                Text(why).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("关闭") { app.cancelPairing() }
            }
        }
        .padding(30)
        .frame(width: 520)
    }

    private var colors: some View {
        HStack(spacing: 10) {
            ForEach(Array((app.pairing?.colors ?? []).enumerated()), id: \.offset) { i, c in
                VStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: c.rgb.0, green: c.rgb.1, blue: c.rgb.2))
                        .frame(width: 38, height: 38)
                        .shadow(color: Color(red: c.rgb.0, green: c.rgb.1, blue: c.rgb.2).opacity(0.6), radius: 6)
                    Text(c.name).font(.callout)
                    Text("\(i + 1)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: fingers

struct FingersPage: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var renaming: FingerInfo?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "指纹", subtitle: "指纹只保存在这台 Mac 上，加密文件要这张卡和这台 Mac 一起才能解开；拔卡后立即从内存清除。卡上不存任何指纹。")
            if app.fingerStore == .orphan {
                Panel {
                    Text("这张卡解不开现有的指纹库：解除配对或恢复出厂时，旧密钥已经销毁。").foregroundStyle(.orange)
                    Button("删除旧指纹库，重新录入…") { app.discardFingers() }
                }
            } else if case .failed(let why) = app.fingerStore {
                Panel { Text("指纹库打不开：\(why)").foregroundStyle(.orange) }
            } else if app.fingerStore == .locked {
                Panel { Text("插入已配对的卡后，指纹库才会解开。").foregroundStyle(.secondary) }
            }
            Button {
                app.authenticate("查看指纹图像") { openWindow(id: "camera") }
            } label: { Label("指纹摄像头", systemImage: "video") }
            .disabled(app.pairedCard == nil)
            Panel {
                if app.fingers.isEmpty {
                    HStack {
                        Text(app.fingerStore == .open ? "还没有录入指纹" : "指纹库未解开").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                ForEach(app.fingers) { f in
                    HStack(spacing: 12) {
                        Image(systemName: "touchid").font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.headline)
                            Text("录入于 \(f.created) · 模板 \(f.samples) 张（解锁时会自动补充）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重命名") {
                            newName = f.name
                            renaming = f
                        }
                        Button(role: .destructive) { app.delete(f.id) } label: { Image(systemName: "trash") }
                    }
                    if f != app.fingers.last { Divider() }
                }
                HStack {
                    Button {
                        app.startEnroll()
                    } label: {
                        Label("添加指纹", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.pairedCard == nil)
                    if app.pairedCard == nil {
                        Text("先插入并配对指纹卡").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("更多") {
                        Button("从开发工具导入（fpdb）…") { app.importPlain() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Panel(title: "失败保护") {
                Text("连续失败 5 次锁定 30 秒；累计失败 \(UnlockGuard.limit) 次停用指纹，要验证 Mac 密码才能恢复。解锁成功时累计清零。识别结果只显示“通过 / 不通过”，不显示相似度分数。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("当前累计失败：\(UnlockGuard.failures) 次")
                    Spacer()
                    if UnlockGuard.blocked { Button("重新启用指纹") { app.resetFailures() } }
                }
            }
        }
        .sheet(item: $renaming) { f in
            VStack(alignment: .leading, spacing: 14) {
                Text("重命名指纹").font(.headline)
                TextField("名称", text: $newName).textFieldStyle(.roundedBorder).frame(width: 280)
                HStack {
                    Spacer()
                    Button("取消") { renaming = nil }
                    Button("好") {
                        let n = newName.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { app.rename(f.id, n) }
                        renaming = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
    }
}

struct EnrollSheet: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let e = app.enroll ?? EnrollFlow()
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 26) {
                Ring(value: e.progress, text: e.finished != nil ? "完成" : "\(e.done) / \(e.steps)",
                     done: e.finished != nil, size: 170)
                    .animation(.easeOut(duration: 0.35), value: e.progress)
                VStack(alignment: .leading, spacing: 10) {
                    Text(e.finished != nil ? "已添加指纹" : e.title).font(.title2.bold())
                    Text(e.finished != nil ? "以后按这个手指就能解锁。" : e.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !e.hint.isEmpty && e.finished == nil {
                        Text(e.hint).foregroundStyle(e.hintIsProblem ? Color.red : Color.secondary)
                    }
                    Spacer(minLength: 0)
                    TouchGlyph(active: app.touching, size: 34, waiting: e.finished == nil)
                }
                .frame(width: 300, alignment: .leading)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04))
                if let m = e.mosaic {
                    Image(decorative: m, scale: 1).resizable().interpolation(.medium).scaledToFit().padding(8)
                } else {
                    Text("录入的区域会在这里拼起来").foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
            HStack {
                if app.pairedCard == nil {
                    Label("卡没有连上", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                if e.finished != nil {
                    Button("完成") { app.enroll = nil }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { app.cancelEnroll() }
                }
            }
        }
        .padding(26)
        .frame(width: 600)
    }
}
