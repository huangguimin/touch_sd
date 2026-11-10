// Draws the app icon on a rounded square, as an .iconset: the card from above for the
// product (contacts, chamfer, the sensor along the tail, an LED lit at each ear), the
// touchid glyph for the lab tool.
// swift scripts/make_icon.swift <out.iconset> [lab]
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let lab = args.count > 2 && args[2] == "lab"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the shape fills ~80% of the canvas
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let top = lab ? NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.40, alpha: 1)
                  : NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.31, alpha: 1)
    let bottom = lab ? NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1)
                     : NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    if !lab {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        cardTop(in: rect, px: px)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    // glyph, tinted with a cyan-to-violet gradient
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.56, weight: .regular)
    if let sym = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let gs = sym.size
        let r = NSRect(x: rect.midX - gs.width / 2, y: rect.midY - gs.height / 2, width: gs.width, height: gs.height)
        let mask = NSImage(size: gs, flipped: false) { b in
            sym.draw(in: b)
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            let g = lab ? NSGradient(starting: NSColor(calibratedRed: 1, green: 0.75, blue: 0.3, alpha: 1),
                                     ending: NSColor(calibratedRed: 1, green: 0.45, blue: 0.2, alpha: 1))!
                        : NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.9, blue: 1, alpha: 1),
                                     ending: NSColor(calibratedRed: 0.55, green: 0.45, blue: 1, alpha: 1))!
            g.draw(in: b, angle: -60)
            return true
        }
        mask.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let cyan = NSColor(calibratedRed: 0.35, green: 0.9, blue: 1, alpha: 1)
let violet = NSColor(calibratedRed: 0.62, green: 0.45, blue: 1, alpha: 1)

/// The card from above, contacts up and the tail down: 24 x 16 mm with the chamfer, the
/// ears 26.3 wide, the 14.5 mm sensor along the tail and an LED at each ear.
func cardTop(in rect: NSRect, px: Int) {
    let w = rect.width * 0.66, u = w / 24
    let o = NSPoint(x: rect.midX - w / 2, y: rect.midY + rect.width * 0.02 - 8 * u)
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: o.x + x * u, y: o.y + y * u) }
    let leds = [(p(1.5, 1.3), cyan), (p(22.5, 1.3), violet)]
    for (c, col) in leds {
        NSGradient(starting: col.withAlphaComponent(0.6), ending: col.withAlphaComponent(0))!
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: 9 * u, options: [])
    }
    let body = NSBezierPath()
    body.move(to: p(0, 2))
    body.line(to: p(0, 15.3))
    body.curve(to: p(0.7, 16), controlPoint1: p(0, 15.7), controlPoint2: p(0.3, 16))
    body.line(to: p(19.8, 16))
    body.line(to: p(24, 11.8))
    body.line(to: p(24, 2))
    body.close()
    body.append(NSBezierPath(roundedRect: NSRect(x: o.x - 1.15 * u, y: o.y, width: 26.3 * u, height: 2.6 * u),
                             xRadius: 1.3 * u, yRadius: 1.3 * u))
    body.windingRule = .nonZero
    NSGradient(colors: [NSColor(calibratedWhite: 0.92, alpha: 1), NSColor(calibratedWhite: 0.68, alpha: 1),
                        NSColor(calibratedWhite: 0.5, alpha: 1)])!.draw(in: body, angle: -90)
    NSColor(calibratedRed: 0.84, green: 0.69, blue: 0.36, alpha: 1).setFill()
    for i in 0..<8 {
        NSBezierPath(roundedRect: NSRect(x: o.x + (1.5 + CGFloat(i) * 2.15) * u, y: o.y + 11.8 * u, width: 1.3 * u, height: 3.2 * u),
                     xRadius: 0.25 * u, yRadius: 0.25 * u).fill()
    }
    let sensor = NSBezierPath(roundedRect: NSRect(x: o.x + 4.75 * u, y: o.y + 0.25 * u, width: 14.5 * u, height: 2.1 * u),
                              xRadius: 1.05 * u, yRadius: 1.05 * u)
    NSColor(calibratedWhite: 0.03, alpha: 1).setFill()
    sensor.fill()
    if px >= 64 {
        // ridges, as the sensor sees a finger sliding past
        NSGraphicsContext.saveGraphicsState()
        sensor.addClip()
        for i in 0..<9 {
            let ridge = NSBezierPath()
            ridge.appendArc(withCenter: p(13, -9), radius: (9.3 + CGFloat(i) * 0.33) * u, startAngle: 40, endAngle: 140)
            ridge.lineWidth = 0.13 * u
            ridge.lineCapStyle = .round
            (cyan.blended(withFraction: CGFloat(i) / 8, of: violet) ?? cyan).setStroke()
            ridge.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    // the LEDs themselves, out at the ends of the ears
    for (c, col) in [(p(0.1, 1.3), cyan), (p(23.9, 1.3), violet)] {
        col.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 0.7 * u, y: c.y - 0.7 * u, width: 1.4 * u, height: 1.4 * u)).fill()
    }
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
