import AppKit

/// The Burn flame, drawn in a unit box (x 0...1, y 0...1, y up) scaled into `rect`.
/// Shared by the menu-bar glyph and scripts/icon, so the logo and the glyph never drift apart.
enum FlameGlyph {
    /// `sway` (-1...1) bends the tips sideways and `stretch` (0...1) makes them taller, for the flicker frames.
    static func body(in rect: CGRect, sway: CGFloat = 0, stretch: CGFloat = 0) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            // Points high on the flame move more than the base.
            let lift = max(0, y - 0.35) / 0.65
            let x = x + sway * 0.09 * lift
            let y = y + stretch * 0.1 * lift
            return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let f = CGMutablePath()
        f.move(to: p(0.5, 0))
        f.addCurve(to: p(0.96, 0.32), control1: p(0.80, 0), control2: p(0.96, 0.13))
        f.addCurve(to: p(0.86, 0.72), control1: p(0.98, 0.50), control2: p(0.93, 0.63))
        f.addCurve(to: p(0.69, 0.50), control1: p(0.80, 0.60), control2: p(0.73, 0.54))
        f.addCurve(to: p(0.47, 1.0), control1: p(0.72, 0.74), control2: p(0.56, 0.86))
        f.addCurve(to: p(0.31, 0.50), control1: p(0.42, 0.84), control2: p(0.28, 0.72))
        f.addCurve(to: p(0.14, 0.72), control1: p(0.27, 0.54), control2: p(0.18, 0.60))
        f.addCurve(to: p(0.04, 0.32), control1: p(0.07, 0.63), control2: p(0.02, 0.50))
        f.addCurve(to: p(0.5, 0), control1: p(0.04, 0.13), control2: p(0.20, 0))
        return f
    }

    /// Clawd's eyes. `open` 0 closes them to a slit for a blink.
    static func eyes(in rect: CGRect, open: CGFloat = 1) -> [CGRect] {
        let w = 0.07 * rect.width, h = max(0.025, 0.14 * open) * rect.height
        let y = rect.minY + (0.24 + 0.07 * (1 - open)) * rect.height
        return [0.39, 0.59].map { CGRect(x: rect.minX + $0 * rect.width - w / 2, y: y, width: w, height: h) }
    }

    /// Flame with the eyes cut out. Even-odd fill keeps the eyes transparent.
    static func path(in rect: CGRect, sway: CGFloat = 0, eyesOpen: CGFloat = 1) -> CGPath {
        let p = CGMutablePath()
        p.addPath(body(in: rect, sway: sway, stretch: 0))
        let r = min(rect.width, rect.height) * 0.02
        for e in eyes(in: rect, open: eyesOpen) {
            p.addPath(CGPath(roundedRect: e, cornerWidth: r, cornerHeight: r, transform: nil))
        }
        return p
    }

    struct Style {
        enum Kind { case linear, core, nested }
        let name: String
        /// Bottom to top for linear; centre to edge for core.
        let colors: [NSColor]
        let kind: Kind
        let eyes: NSColor
    }

    static func srgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    static let ink = srgb(0x1e1e1f)
    /// Clui's terracotta at the base, warming toward amber tips.
    static let terracotta = Style(name: "terracotta", colors: [srgb(0xde7356), srgb(0xe98a5b), srgb(0xf6b468)], kind: .linear, eyes: ink)

    static func draw(_ c: CGContext, in rect: CGRect, style: Style, sway: CGFloat = 0, stretch: CGFloat = 0, eyesOpen: CGFloat = 1) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let grad = CGGradient(colorsSpace: space, colors: style.colors.map(\.cgColor) as CFArray, locations: nil)!
        let outline = body(in: rect, sway: sway, stretch: stretch)
        c.saveGState()
        c.addPath(outline)
        c.clip()
        switch style.kind {
        case .linear:
            c.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        case .core:
            let centre = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.28)
            c.drawRadialGradient(grad, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: rect.height * 0.8, options: .drawsAfterEndLocation)
        case .nested:
            c.setFillColor(style.colors[0].cgColor)
            c.fill(rect)
            // A smaller copy of the same flame inside, like the hotter inner fire.
            let inner = CGRect(x: rect.midX - rect.width * 0.29, y: rect.minY + rect.height * 0.06, width: rect.width * 0.58, height: rect.height * 0.6)
            c.addPath(body(in: inner, sway: sway))
            c.clip()
            c.drawLinearGradient(grad, start: CGPoint(x: inner.midX, y: inner.minY), end: CGPoint(x: inner.midX, y: inner.maxY), options: [])
        }
        c.restoreGState()
        let r = min(rect.width, rect.height) * 0.02
        c.setFillColor(style.eyes.cgColor)
        for e in eyes(in: rect, open: eyesOpen) {
            c.addPath(CGPath(roundedRect: e, cornerWidth: r, cornerHeight: r, transform: nil))
        }
        c.fillPath()
    }

    /// Menu-bar flicker, rendered once to bitmaps so a frame tick is only an image swap.
    static let frames: [NSImage] = (0..<12).map { i in
        let t = CGFloat(i) / 12
        let heat = sin(t * .pi)
        return menuBarImage(template: false) { c, r in
            draw(c, in: r, style: terracotta,
                 sway: sin(t * 2 * .pi) * (0.4 + 0.6 * heat), stretch: heat, eyesOpen: i == 8 ? 0 : 1)
        }
    }

    /// Shown in colour while spend is landing.
    static let lit = menuBarImage(template: false) { c, r in draw(c, in: r, style: terracotta) }

    /// Monochrome when idle, tinted by macOS like every other menu-bar icon.
    static let idle = menuBarImage(template: true) { c, r in
        c.addPath(path(in: r))
        c.setFillColor(NSColor.black.cgColor)
        c.fillPath(using: .evenOdd)
    }

    private static func menuBarImage(template: Bool, _ paint: (CGContext, CGRect) -> Void) -> NSImage {
        let pt: CGFloat = 16, scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pt * scale), pixelsHigh: Int(pt * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let c = NSGraphicsContext.current!.cgContext
        c.scaleBy(x: scale, y: scale)
        // Base sits on the text baseline; headroom above the tips is for the stretch frames.
        paint(c, CGRect(x: 1.5, y: 2.5, width: 13, height: 12))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: pt, height: pt)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = template
        // Colour is the only sign that spend is landing, so VoiceOver says it too.
        img.accessibilityDescription = template ? "Burn" : "Burn, spending"
        return img
    }
}
