import SwiftUI

/// Volume bar (or the scroll in scroll mode), the sensor strip with the contact span, and the accumulated movement.
public struct SlideCanvas: View {
    @EnvironmentObject var s: SlideModel

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            Canvas { g, size in
                let pad: CGFloat = 16
                // volume bar
                let bar = CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: 48)
                g.fill(Path(roundedRect: bar, cornerRadius: 8), with: .color(Color(white: 0.24)))
                if s.target == .volume {
                    let fill = CGRect(x: bar.minX, y: bar.minY, width: bar.width * s.volume / 100, height: bar.height)
                    g.fill(Path(roundedRect: fill, cornerRadius: 8),
                           with: .color(s.touching ? Color(red: 0.31, green: 0.67, blue: 1) : Color(red: 0.27, green: 0.47, blue: 0.67)))
                    g.draw(Text("音量 \(Int(s.volume.rounded()))%").font(.system(size: 18, weight: .bold)).foregroundColor(.white),
                           at: CGPoint(x: bar.midX, y: bar.midY))
                } else {
                    let label = s.scrollIdle.isEmpty ?
                        (s.scrolled == 0 ? "滚动页面" : "本次滚动 \(s.scrolled > 0 ? "↓" : "↑") \(Int(abs(s.scrolled))) 像素") : s.scrollIdle
                    g.draw(Text(label).font(.system(size: 17, weight: .bold))
                            .foregroundColor(s.scrollIdle.isEmpty ? .white : .orange),
                           at: CGPoint(x: bar.midX, y: bar.midY))
                }
                // sensor strip, row 0 on the left
                let strip = CGRect(x: pad, y: bar.maxY + 28, width: size.width - 2 * pad, height: 26)
                g.fill(Path(strip), with: .color(Color(white: 0.14)))
                g.stroke(Path(strip), with: .color(.gray))
                if let (lo, hi) = s.span {
                    let x0 = strip.minX + strip.width * CGFloat(lo) / CGFloat(SlideModel.rows)
                    let x1 = strip.minX + strip.width * CGFloat(hi + 1) / CGFloat(SlideModel.rows)
                    g.fill(Path(CGRect(x: x0, y: strip.minY + 2, width: x1 - x0, height: strip.height - 4)),
                           with: .color(Color(red: 1, green: 0.7, blue: 0.24)))
                }
                g.draw(Text("行 0").font(.caption).foregroundColor(.secondary), at: CGPoint(x: strip.minX + 14, y: strip.maxY + 10))
                g.draw(Text("行 151").font(.caption).foregroundColor(.secondary), at: CGPoint(x: strip.maxX - 20, y: strip.maxY + 10))
                // accumulated movement over the last seconds
                let plot = CGRect(x: pad, y: strip.maxY + 30, width: size.width - 2 * pad,
                                  height: max(60, size.height - strip.maxY - 30 - pad))
                g.fill(Path(plot), with: .color(Color(white: 0.1)))
                let now = ctx.date
                let pts = s.trace.filter { now.timeIntervalSince($0.0) <= SlideModel.traceSeconds }
                if pts.count >= 2 {
                    let vals = pts.map { Double($0.1) }
                    let lo = vals.min()!, hi = vals.max()!
                    let span = max(hi - lo, 50), mid = (hi + lo) / 2
                    var path = Path()
                    for (i, p) in pts.enumerated() {
                        let x = plot.maxX - plot.width * now.timeIntervalSince(p.0) / SlideModel.traceSeconds
                        let y = plot.midY - plot.height * 0.45 * (Double(p.1) - mid) / (span / 2)
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    g.stroke(path, with: .color(Color(red: 0.47, green: 0.86, blue: 0.55)), lineWidth: 2)
                }
                g.draw(Text("累计位移（行），最近 \(Int(SlideModel.traceSeconds)) 秒").font(.caption).foregroundColor(.gray),
                       at: CGPoint(x: plot.minX + 90, y: plot.minY + 12))
            }
        }
        .frame(minHeight: 320)
    }
}
