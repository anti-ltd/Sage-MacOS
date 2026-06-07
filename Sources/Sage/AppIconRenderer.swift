import AppKit
import SwiftUI

func iconSquircle(_ rect: CGRect, ratio: CGFloat = 0.2237) -> CGPath {
    RoundedRectangle(cornerRadius: min(rect.width, rect.height) * ratio, style: .continuous)
        .path(in: rect).cgPath
}

enum AppIconRenderer {
    static let symbolName = "bubble.left.and.bubble.right.fill"

    static func run(directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let specs: [(base: Int, scale: Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
        ]
        for spec in specs {
            let px = spec.base * spec.scale
            guard let data = png(size: CGFloat(px)) else { continue }
            let name = spec.scale == 1
                ? "icon_\(spec.base)x\(spec.base).png"
                : "icon_\(spec.base)x\(spec.base)@2x.png"
            try? data.write(to: dir.appendingPathComponent(name))
        }
        FileHandle.standardError.write(Data("Icon written to \(directory)\n".utf8))
    }

    private static func png(size: CGFloat) -> Data? {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        draw(in: ctx.cgContext, size: size)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(in cg: CGContext, size: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            CGColor(red: r, green: g, blue: b, alpha: a)
        }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let bg = iconSquircle(rect)

        // Sage green background gradient
        cg.saveGState()
        cg.addPath(bg)
        cg.clip()
        let bgGrad = CGGradient(colorsSpace: space, colors: [
            rgb(0.20, 0.50, 0.38),   // sage green, top-left
            rgb(0.10, 0.30, 0.22),   // deep forest, mid
            rgb(0.04, 0.14, 0.10),   // near-black, bottom-right
        ] as CFArray, locations: [0, 0.55, 1])!
        cg.drawLinearGradient(bgGrad,
                              start: CGPoint(x: rect.minX, y: rect.maxY),
                              end: CGPoint(x: rect.maxX, y: rect.minY),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()

        // Subtle rim
        cg.saveGState()
        cg.addPath(bg)
        cg.setLineWidth(size * 0.008)
        cg.setStrokeColor(rgb(1, 1, 1, 0.15))
        cg.strokePath()
        cg.restoreGState()

        // Centered SF Symbol — speech bubbles, white, ~50% of canvas
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.50, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let glyph = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        guard let cgImg = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let s = glyph.size
        let origin = CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
        cg.saveGState()
        cg.addPath(bg)
        cg.clip()
        cg.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.025,
                     color: rgb(0, 0, 0, 0.40))
        cg.draw(cgImg, in: CGRect(origin: origin, size: s))
        cg.restoreGState()
    }
}
