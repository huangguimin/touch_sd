import AppKit
import SwiftUI

/// The two LEDs on the card: left to the firmware, or held at colours chosen here.
@MainActor
final class CardLEDs: ObservableObject {
    @Published var custom: Bool { didSet { changed() } }
    @Published var first: Color { didSet { changed() } }
    @Published var second: Color { didSet { changed() } }
    /// nil hands the LEDs back to the firmware.
    var apply: (([UInt8]?) -> Void)? { didSet { send() } }

    init() {
        let d = UserDefaults.standard
        custom = d.bool(forKey: "leds.custom")
        first = CardLEDs.color(d.string(forKey: "leds.first"))
        second = CardLEDs.color(d.string(forKey: "leds.second"))
    }

    private func changed() {
        let d = UserDefaults.standard
        d.set(custom, forKey: "leds.custom")
        d.set(CardLEDs.hex(first), forKey: "leds.first")
        d.set(CardLEDs.hex(second), forKey: "leds.second")
        send()
    }

    private func send() {
        apply?(custom ? CardLEDs.bytes(first) + CardLEDs.bytes(second) : nil)
    }

    private static func bytes(_ c: Color) -> [UInt8] {
        guard let s = NSColor(c).usingColorSpace(.sRGB) else { return [0, 0, 0] }
        return [s.redComponent, s.greenComponent, s.blueComponent].map { UInt8(max(0, min(1, $0)) * 255) }
    }

    private static func hex(_ c: Color) -> String {
        bytes(c).map { String(format: "%02x", $0) }.joined()
    }

    private static func color(_ hex: String?) -> Color {
        guard let hex, hex.count == 6, let v = Int(hex, radix: 16) else { return .blue }
        return Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}

struct LEDPanel: View {
    @ObservedObject var leds: CardLEDs

    var body: some View {
        Panel(title: "指示灯") {
            Toggle("由 App 控制两颗灯", isOn: $leds.custom).toggleStyle(.switch)
            if leds.custom {
                ColorPicker("前灯", selection: $leds.first, supportsOpacity: false)
                ColorPicker("后灯", selection: $leds.second, supportsOpacity: false)
            }
            Text("打开后按压时不再显示蓝绿反馈。App 退出或拔卡后，几秒内交还固件。配对和恢复出厂时，灯仍由卡显示校验颜色。亮度上限由卡决定。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
