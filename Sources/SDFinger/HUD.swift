import AppKit
import SwiftUI

/// A small floating panel at the top of the screen: unlock feedback while another app is
/// in front, and the sudo prompt.  It never takes focus.
@MainActor
final class HUDPanel {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var sudoShown = false

    private func present<V: View>(_ view: V, width: CGFloat = 340) {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = false
            return p
        }()
        panel = p
        p.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12,
                          width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
    }

    func flash(_ f: Feedback) {
        guard !sudoShown else { return }
        present(FeedbackCard(feedback: f))
        panel?.ignoresMouseEvents = true
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.sudoShown else { return }
            self.panel?.orderOut(nil)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    func showSudo(user: String, cancel: @escaping () -> Void) {
        sudoShown = true
        hideWork?.cancel()
        showPrompt(title: "终端请求管理员权限", detail: "sudo（用户 \(user)）· 在指纹卡上按一下手指", cancel: cancel)
    }
    func showPrompt(title: String, detail: String, cancel: @escaping () -> Void) {
        sudoShown = true
        hideWork?.cancel()
        present(SudoCard(title: title, detail: detail, cancel: cancel), width: 380)
        panel?.ignoresMouseEvents = false   // its Cancel button
    }

    func hideSudo() {
        guard sudoShown else { return }
        sudoShown = false
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

struct FeedbackCard: View {
    let feedback: Feedback

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: feedback.tone == .ok ? "checkmark.circle.fill" :
                    feedback.tone == .fail ? "xmark.circle.fill" : "touchid")
                .font(.system(size: 28))
                .foregroundStyle(feedback.tone == .ok ? .green : feedback.tone == .fail ? .red : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title).font(.headline)
                if !feedback.detail.isEmpty {
                    Text(feedback.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SudoCard: View {
    let title: String
    let detail: String
    let cancel: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "touchid")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("取消", action: cancel)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
