import CoreGraphics
import CvBridge
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Enrolled fingers: fpdb/fingers.json plus one directory per finger with the samples as
/// 152 x 35 raw grey PNGs -- the same layout as host/fpgui/store.py, so both tools share it.
public final class Finger {
    public let id: Int
    public var name: String
    public let created: String
    public var files: [String]
    public var samples: [FPSample] = []

    init(id: Int, name: String, created: String, files: [String]) {
        self.id = id
        self.name = name
        self.created = created
        self.files = files
    }
}

public final class Store {
    public let root: URL
    public private(set) var fingers: [Finger] = []
    private var params: FPParams

    public init(root: URL, params: FPParams) {
        self.root = root
        self.params = params
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fingers.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for d in list {
            guard let id = d["id"] as? Int, let name = d["name"] as? String else { continue }
            let g = Finger(id: id, name: name, created: d["created"] as? String ?? "",
                           files: d["samples"] as? [String] ?? [])
            for f in g.files {
                if let raw = GreyPNG.read(root.appendingPathComponent(f)) {
                    g.samples.append(FPSample(raw: raw, params: params))
                }
            }
            fingers.append(g)
        }
    }

    private func saveIndex() {
        let list: [[String: Any]] = fingers.map {
            ["id": $0.id, "name": $0.name, "created": $0.created, "samples": $0.files]
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? data.write(to: root.appendingPathComponent("fingers.json"))
        }
    }

    @discardableResult
    public func add(_ samples: [FPSample]) -> Finger {
        let id = (fingers.map { $0.id }.max() ?? 0) + 1
        let used = Set(fingers.map { $0.name })
        var k = 1
        while used.contains("指纹 \(k)") { k += 1 }
        let dir = "f\(id)"
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(dir),
                                                 withIntermediateDirectories: true)
        var files: [String] = []
        for (i, s) in samples.enumerated() {
            let f = String(format: "%@/s%02d.png", dir, i)
            GreyPNG.write(s.raw, to: root.appendingPathComponent(f))
            files.append(f)
        }
        let g = Finger(id: id, name: "指纹 \(k)", created: Stamp.human(), files: files)
        g.samples = samples
        fingers.append(g)
        saveIndex()
        return g
    }

    /// Adaptive update: add an accepted unlock press to the finger's template.
    public func append(_ g: Finger, _ s: FPSample) {
        let next = (g.files.compactMap { Int($0.dropLast(4).suffix(2)) }.max() ?? -1) + 1
        let f = String(format: "f%d/s%02d.png", g.id, next)
        GreyPNG.write(s.raw, to: root.appendingPathComponent(f))
        g.files.append(f)
        g.samples.append(s)
        saveIndex()
    }

    public func rename(_ g: Finger, _ name: String) {
        g.name = name
        saveIndex()
    }

    public func remove(_ g: Finger) {
        fingers.removeAll { $0 === g }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("f\(g.id)"))
        saveIndex()
    }

    /// Parameters changed: extract the features again.
    public func recompute(_ p: FPParams) {
        params = p
        for g in fingers {
            g.samples = g.samples.map { FPSample(raw: $0.raw, params: p) }
        }
    }
}

/// 8-bit grey PNG <-> raw bytes, without colour management touching the values.
public enum GreyPNG {
    public static func read(_ url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == FrameImage.cols, img.height == FrameImage.rows else { return nil }
        if img.bitsPerPixel == 8, img.bitsPerComponent == 8,
           let data = img.dataProvider?.data as Data? {
            var out = Data(capacity: img.width * img.height)
            for r in 0..<img.height {
                out.append(data.subdata(in: r * img.bytesPerRow..<(r * img.bytesPerRow + img.width)))
            }
            return out
        }
        // Anything else: draw into a grey context with no colour conversion.
        var out = Data(count: img.width * img.height)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height,
                                bitsPerComponent: 8, bytesPerRow: img.width,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return out
    }

    public static func write(_ raw: Data, to url: URL, width: Int = FrameImage.cols,
                             height: Int = FrameImage.rows) {
        guard let img = Images.grey(raw, width: width, height: height),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }
}

/// Raw buffers -> CGImage for display and saving.
public enum Images {
    public static func grey(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func rgba(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
