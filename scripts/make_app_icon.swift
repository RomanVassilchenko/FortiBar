#!/usr/bin/env swift
// Draws the FortiBar app icon at every size in the appiconset (PNG with alpha), and optionally the
// website icons from the same drawing.
//
//     swift scripts/make_app_icon.swift FortiBar/Assets.xcassets/AppIcon.appiconset [docs/assets]
//
// The mark: a monogram "F" built from rounded bars on a deep midnight-blue tile. The top bar is
// the menu bar, and the middle bar ends in a green "connected" node (the app's green for a live
// tunnel). White mark, one accent colour, nothing else.
//
// Layout follows the macOS icon grid: an 824pt continuous-corner squircle centred in a
// 1024pt canvas. All geometry below is in that 1024pt space; each size is rendered directly
// (not downscaled from the master) so 16/32/64 px can use heavier, pixel-snapped bars and stay crisp.
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let docsDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

// MARK: - Palette

enum Palette {
    // Tile: cool blue light at the top left, sinking into midnight navy
    static let tileTop: UInt32 = 0x3566e0
    static let tileMid: UInt32 = 0x1b2e92
    static let tileBottom: UInt32 = 0x0b1140
    // Mark: white easing into a cool blue-grey
    static let markTop: UInt32 = 0xffffff
    static let markBottom: UInt32 = 0xdbe3f7
    // "Connected" node
    static let node: UInt32 = 0x34d96a
    static let nodeLight: UInt32 = 0x8ff0ae
    static let nodeTiny: UInt32 = 0x52ec86 // brighter, so 2 px still glow at 16 px
}

/// Level of detail: small sizes get heavier, pixel-snapped bars and no fine effects.
enum Detail { case tiny, small, medium, full }

func detail(for px: Int) -> Detail {
    switch px {
    case ..<24: return .tiny
    case ..<48: return .small
    case ..<100: return .medium
    default: return .full
    }
}

// MARK: - Shapes (1024pt space, y up)

/// Continuous-corner squircle like the macOS icon mask: straight sides, and each corner is a
/// superellipse quadrant (|x|^n + |y|^n = 1, n = 3) spanning `corner` points, so curvature ramps
/// up from zero instead of jumping as with a circular arc. corner 280 ≈ the 185pt grid radius.
func squircle(_ rect: CGRect, corner c: CGFloat = 280, n: CGFloat = 3) -> CGPath {
    let path = CGMutablePath()
    // Corner centres and the quadrant each sweeps (angle offset)
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: rect.maxX - c, y: rect.maxY - c), 0),
        (CGPoint(x: rect.minX + c, y: rect.maxY - c), .pi / 2),
        (CGPoint(x: rect.minX + c, y: rect.minY + c), .pi),
        (CGPoint(x: rect.maxX - c, y: rect.minY + c), 3 * .pi / 2),
    ]
    let steps = 90
    for (k, (o, start)) in corners.enumerated() {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * .pi / 2
            let ct = cos(t), st = sin(t)
            let p = CGPoint(x: o.x + c * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
                            y: o.y + c * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
            if k == 0 && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }
    path.closeSubpath()
    return path
}

/// Geometry of the "F" mark and its node, per level of detail.
struct Mark {
    var left: CGFloat      // stem's left edge
    var top: CGFloat       // top bar's top edge
    var bottom: CGFloat    // stem's bottom end
    var bar: CGFloat       // bar thickness
    var topLength: CGFloat // top bar, from the stem's left edge
    var armLength: CGFloat // middle bar, from the stem's left edge
    var armY: CGFloat      // middle bar's centre line
    var nodeX: CGFloat     // node centre
    var nodeR: CGFloat
    var endRadius: CGFloat // bar ends (bar / 2 = fully round)
    var innerRadius: CGFloat

    static func forDetail(_ lod: Detail) -> Mark {
        switch lod {
        case .full:
            return Mark(left: 306, top: 768, bottom: 256, bar: 116, topLength: 440, armLength: 226, armY: 506,
                        nodeX: 306 + 226 + 46 + 62, nodeR: 62, endRadius: 58, innerRadius: 18)
        case .medium:
            return Mark(left: 300, top: 772, bottom: 252, bar: 128, topLength: 448, armLength: 228, armY: 504,
                        nodeX: 300 + 228 + 44 + 70, nodeR: 70, endRadius: 64, innerRadius: 16)
        // 32 px: 32 units per pixel. 4 px bars, 1 px gap before a 4 px node.
        case .small:
            return Mark(left: 320, top: 768, bottom: 256, bar: 128, topLength: 416, armLength: 256, armY: 512,
                        nodeX: 672, nodeR: 64, endRadius: 40, innerRadius: 0)
        // 16 px: 64 units per pixel. 2 px bars, 1 px gap before a 2 px node.
        case .tiny:
            return Mark(left: 320, top: 768, bottom: 256, bar: 128, topLength: 448, armLength: 256, armY: 512,
                        nodeX: 704, nodeR: 64, endRadius: 0, innerRadius: 0)
        }
    }

    /// One closed outline (no overlapping subpaths), so rims and shadows have no seams.
    var path: CGPath {
        let x0 = left, x1 = left + bar, xr = left + topLength, xa = left + armLength
        let yb = top - bar, ya1 = armY + bar / 2, ya0 = armY - bar / 2
        let R = endRadius, r = innerRadius
        let corners: [(CGFloat, CGFloat, CGFloat)] = [
            (x0, top, R), (xr, top, R), (xr, yb, R), (x1, yb, r), (x1, ya1, r),
            (xa, ya1, R), (xa, ya0, R), (x1, ya0, r), (x1, bottom, R), (x0, bottom, R),
        ]
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: (top + bottom) / 2))
        for (i, c) in corners.enumerated() {
            let next = corners[(i + 1) % corners.count]
            let corner = CGPoint(x: c.0, y: c.1)
            if c.2 > 0 {
                p.addArc(tangent1End: corner, tangent2End: CGPoint(x: next.0, y: next.1), radius: c.2)
            } else {
                p.addLine(to: corner)
            }
        }
        p.closeSubpath()
        return p
    }

    var node: CGRect { CGRect(x: nodeX - nodeR, y: armY - nodeR, width: 2 * nodeR, height: 2 * nodeR) }
}

// MARK: - Drawing

/// `fullBleed`: the tile fills the whole square (for apple-touch-icon, which the OS masks itself).
func render(px: Int, fullBleed: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    if fullBleed {
        // Map the 824pt tile onto the whole canvas
        let k = 1024 / 824.0
        ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -512, y: -512)
        s *= k
    }
    ctx.interpolationQuality = .high
    let lod = detail(for: px)
    let fine = lod == .full || lod == .medium

    // Shadows ignore the CTM, so scale them by hand
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: dy * s), blur: blur * s, color: c)
    }
    /// Stroke drawn only inside `path` (an inner rim), filled with a vertical gradient.
    func innerRim(_ path: CGPath, width: CGFloat, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.addPath(path); ctx.setLineWidth(width * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
        ctx.restoreGState()
    }

    // Background tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = fullBleed ? CGPath(rect: tile.insetBy(dx: -2, dy: -2), transform: nil) : squircle(tile)

    if !fullBleed {
        ctx.saveGState()
        shadow(-10, 20, color(0x000000, lod == .tiny ? 0.18 : 0.30))
        ctx.addPath(body); ctx.setFillColor(color(Palette.tileMid)); ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(FortiBarGradients.tile, start: CGPoint(x: 380, y: 924), end: CGPoint(x: 640, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Soft light from the top left, as if lit through glass
    ctx.drawRadialGradient(FortiBarGradients.topLight, startCenter: CGPoint(x: 380, y: 960), startRadius: 0,
                           endCenter: CGPoint(x: 380, y: 960), endRadius: 640, options: [])
    ctx.restoreGState()

    if lod != .tiny && !fullBleed {
        // Rim light: bright along the top edge, fading out
        innerRim(body, width: fine ? 4 : 10, FortiBarGradients.tileRim, top: 924, bottom: 100)
    }

    let mark = Mark.forDetail(lod)
    let f = mark.path
    let node = mark.node

    // Mark: soft ambient shadow + a tighter contact shadow under the foreground layer
    ctx.saveGState()
    shadow(-18, 40, color(0x020818, lod == .tiny ? 0 : lod == .small ? 0.30 : 0.42))
    ctx.addPath(f); ctx.setFillColor(color(Palette.markTop)); ctx.fillPath()
    ctx.restoreGState()
    if fine {
        ctx.saveGState()
        shadow(-4, 8, color(0x020818, 0.25))
        ctx.addPath(f); ctx.setFillColor(color(Palette.markTop)); ctx.fillPath()
        ctx.restoreGState()
    }
    // Face: white easing into a cool blue-grey
    ctx.saveGState(); ctx.addPath(f); ctx.clip()
    ctx.drawLinearGradient(FortiBarGradients.mark, start: CGPoint(x: 0, y: mark.top), end: CGPoint(x: 0, y: mark.bottom),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    if fine {
        // Crisp light catching the top edges, a faint cool edge underneath
        innerRim(f, width: 5, FortiBarGradients.markRim, top: mark.top, bottom: mark.bottom)
    }

    // Node: the "connected" green, with a soft glow
    if lod != .tiny {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: (fine ? 90 : 40) * s, color: color(Palette.node, fine ? 0.75 : 0.5))
        ctx.setFillColor(color(Palette.node)); ctx.fillEllipse(in: node)
        ctx.restoreGState()
    }
    ctx.saveGState(); ctx.addEllipse(in: node); ctx.clip()
    if lod == .tiny {
        ctx.setFillColor(color(Palette.nodeTiny)); ctx.fill(node)
    } else {
        ctx.drawLinearGradient(FortiBarGradients.node, start: CGPoint(x: 0, y: node.maxY), end: CGPoint(x: 0, y: node.minY), options: [])
    }
    ctx.restoreGState()
    if fine {
        innerRim(CGPath(ellipseIn: node, transform: nil), width: 4, FortiBarGradients.nodeRim, top: node.maxY, bottom: node.minY)
    }

    return ctx.makeImage()!
}

enum FortiBarGradients {
    static let tile = gradient([(color(Palette.tileTop), 0), (color(Palette.tileMid), 0.55), (color(Palette.tileBottom), 1)])
    static let topLight = gradient([(color(0xffffff, 0.14), 0), (color(0xffffff, 0), 1)])
    static let tileRim = gradient([(color(0xffffff, 0.45), 0), (color(0xffffff, 0.06), 0.5), (color(0xffffff, 0.02), 1)])
    static let mark = gradient([(color(Palette.markTop), 0), (color(Palette.markBottom), 1)])
    static let markRim = gradient([(color(0xffffff, 1), 0), (color(0xffffff, 0), 0.22), (color(0x8ea2d6, 0), 0.8), (color(0x8ea2d6, 0.3), 1)])
    static let node = gradient([(color(Palette.nodeLight), 0), (color(Palette.node), 0.55), (color(0x22b956), 1)])
    static let nodeRim = gradient([(color(0xffffff, 0.7), 0), (color(0xffffff, 0), 0.4), (color(0x0b5a26, 0), 0.7), (color(0x0b5a26, 0.35), 1)])
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    write(render(px: px), to: outDir.appendingPathComponent("icon_\(px)x\(px).png"))
}
print("wrote icons to \(outDir.path)")

if let docsDir {
    write(render(px: 256), to: docsDir.appendingPathComponent("icon.png"))
    write(render(px: 32), to: docsDir.appendingPathComponent("favicon.png"))
    write(render(px: 180, fullBleed: true), to: docsDir.appendingPathComponent("apple-touch-icon.png"))
    print("wrote website icons to \(docsDir.path)")
}
