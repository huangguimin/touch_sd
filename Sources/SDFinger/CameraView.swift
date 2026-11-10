import AppKit
@preconcurrency import FingerCore
import SwiftUI

/// What the sensor sees, live.  Nothing here is kept: one frame in memory, shown and replaced.
@MainActor
final class LiveCamera: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var fps = 0.0
    private var last = Date.distantPast

    func clear() {
        image = nil
        fps = 0
    }

    /// 152 x 35 grey, stretched to its own range so a light touch still shows the ridges.
    func push(_ raw: Data) {
        let now = Date()
        let dt = now.timeIntervalSince(last)
        last = now
        if dt < 1 { fps += (1 / max(dt, 0.001) - fps) * 0.15 }
        // the range of what the finger covers: the rest of the sensor reads black
        let sorted = raw.filter { $0 > 25 }.sorted()
        guard !sorted.isEmpty else { return }
        let lo = Int(sorted[sorted.count / 50]), hi = max(lo + 1, Int(sorted[sorted.count * 49 / 50]))
        // raw is 152 rows of 35: turned so the long side runs across the picture
        let rows = FrameImage.rows, cols = FrameImage.cols
        var pixels = [UInt8](repeating: 0, count: rows * cols)
        raw.withUnsafeBytes { src in
            for r in 0..<rows {
                for c in 0..<cols where src[r * cols + c] > 25 {
                    pixels[c * rows + r] = UInt8(min(255, max(0, (Int(src[r * cols + c]) - lo) * 255 / (hi - lo))))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return }
        image = CGImage(width: FrameImage.rows, height: FrameImage.cols, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: FrameImage.rows, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct CameraView: View {
    static let title = "指纹摄像头"
    @EnvironmentObject var app: AppState
    @ObservedObject var camera: LiveCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Rectangle().fill(.black)
                if let image = camera.image, app.touching {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Text(app.pairedCard == nil ? "卡没有连上" : "把手指放到传感器上").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(CGFloat(FrameImage.rows) / CGFloat(FrameImage.cols), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(app.touching ? String(format: "%.0f 帧/秒", camera.fps) : "等待手指").monospacedDigit()
                Spacer()
                Text("图像只显示，不保存。").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(minWidth: 620)
    }
}
