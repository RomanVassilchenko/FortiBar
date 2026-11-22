#!/usr/bin/env swift
// Draws the FortiBar app icon at every size in the appiconset (PNG with alpha).
//
//     swift scripts/make_app_icon.swift FortiBar/Assets.xcassets/AppIcon.appiconset
//
// Layout follows the macOS icon grid: an 824pt continuous-corner squircle centred in a
// 1024pt canvas. All geometry below is in that 1024pt space; each size is rendered directly
// (not downscaled from the master) so 16/32/64 px can drop detail and stay crisp.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// Level of detail: small sizes get a bigger, simpler lock and no fine glass effects.
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

/// Rounded rect with smoothed (continuous-looking) corners.
func smoothRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.28 // extend the corner a bit and ease into it, like a continuous corner
    let rr = min(radius * k, min(r.width, r.height) / 2)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + rr, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + rr),
               control1: CGPoint(x: r.maxX - rr * 0.30, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + rr * 0.30))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
    p.addCurve(to: CGPoint(x: r.maxX - rr, y: r.maxY),
               control1: CGPoint(x: r.maxX, y: r.maxY - rr * 0.30), control2: CGPoint(x: r.maxX - rr * 0.30, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + rr, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - rr),
               control1: CGPoint(x: r.minX + rr * 0.30, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - rr * 0.30))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rr))
    p.addCurve(to: CGPoint(x: r.minX + rr, y: r.minY),
               control1: CGPoint(x: r.minX, y: r.minY + rr * 0.30), control2: CGPoint(x: r.minX + rr * 0.30, y: r.minY))
    p.closeSubpath()
    return p
}

/// Heater shield: gently arched top, soft shoulders, sides that ease into a softened point.
func shieldPath(cx: CGFloat, top: CGFloat, bottom: CGFloat, half: CGFloat) -> CGPath {
    let h = top - bottom
    let shoulderY = top - h * 0.15
    let sideY = top - h * 0.45
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: top))
    p.addCurve(to: CGPoint(x: cx + half, y: shoulderY),
               control1: CGPoint(x: cx + half * 0.6, y: top), control2: CGPoint(x: cx + half, y: top - h * 0.02))
    p.addCurve(to: CGPoint(x: cx + half * 0.985, y: sideY),
               control1: CGPoint(x: cx + half, y: shoulderY - h * 0.1), control2: CGPoint(x: cx + half * 0.995, y: sideY + h * 0.1))
    // Softened point: a small quad at the tip, tangent-continuous with the sides
    let tip = CGPoint(x: cx, y: bottom)
    let ex = half * 0.065, ey = h * 0.013
    let lead: CGFloat = 5.5
    p.addCurve(to: CGPoint(x: cx + ex, y: bottom + ey),
               control1: CGPoint(x: cx + half * 0.96, y: bottom + h * 0.25), control2: CGPoint(x: cx + ex * (1 + lead), y: bottom + ey * (1 + lead)))
    p.addQuadCurve(to: CGPoint(x: cx - ex, y: bottom + ey), control: tip)
    p.addCurve(to: CGPoint(x: cx - half * 0.985, y: sideY),
               control1: CGPoint(x: cx - ex * (1 + lead), y: bottom + ey * (1 + lead)), control2: CGPoint(x: cx - half * 0.96, y: bottom + h * 0.25))
    p.addCurve(to: CGPoint(x: cx - half, y: shoulderY),
               control1: CGPoint(x: cx - half * 0.995, y: sideY + h * 0.1), control2: CGPoint(x: cx - half, y: shoulderY - h * 0.1))
    p.addCurve(to: CGPoint(x: cx, y: top),
               control1: CGPoint(x: cx - half, y: top - h * 0.02), control2: CGPoint(x: cx - half * 0.6, y: top))
    p.closeSubpath()
    return p
}

// MARK: - Drawing

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    let lod = detail(for: px)
    let fine = lod == .full || lod == .medium

    // Shadows ignore the CTM, so scale them by hand
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: dy * s), blur: blur * s, color: c)
    }
    func fillGradient(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
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
    let body = squircle(tile)

    ctx.saveGState()
    shadow(-10, 20, color(0x000000, lod == .tiny ? 0.18 : 0.30))
    ctx.addPath(body); ctx.setFillColor(color(0x1652d8)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(gradient([(color(0x58a6ff), 0), (color(0x2a6cf0), 0.45), (color(0x1440b8), 0.82), (color(0x0e2f8f), 1)]),
                           start: CGPoint(x: 420, y: 924), end: CGPoint(x: 604, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Soft light pooling from the top, as if lit through glass
    ctx.drawRadialGradient(gradient([(color(0xa9d4ff, 0.42), 0), (color(0xa9d4ff, 0), 1)]),
                           startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    // Cool depth at the bottom
    ctx.drawRadialGradient(gradient([(color(0x061a5c, 0.0), 0), (color(0x061a5c, 0.35), 1)]),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 300,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 720, options: [])
    ctx.restoreGState()

    if lod != .tiny {
        // Rim light: bright along the top edge, fading out; faint dark edge at the bottom
        innerRim(body, width: fine ? 5 : 10,
                 gradient([(color(0xffffff, 0.75), 0), (color(0xffffff, 0.12), 0.45), (color(0xffffff, 0.04), 1)]),
                 top: 924, bottom: 100)
        if fine {
            innerRim(body, width: 2.5, gradient([(color(0x000000, 0), 0), (color(0x00103a, 0.35), 1)]), top: 600, bottom: 100)
        }
    }

    // Geometry per level of detail. Small sizes get a chunkier lock that fills more of the shield.
    let cx: CGFloat = 512
    let shieldTop: CGFloat, shieldBottom: CGFloat, shieldHalf: CGFloat
    let lockW: CGFloat, lockH: CGFloat, lockY: CGFloat, lockR: CGFloat
    let shackleR: CGFloat, shackleW: CGFloat, shackleLeg: CGFloat
    switch lod {
    case .full:
        shieldTop = 806; shieldBottom = 204; shieldHalf = 252
        lockW = 240; lockH = 182; lockY = 350; lockR = 40
        shackleR = 72; shackleW = 44; shackleLeg = 44
    case .medium:
        shieldTop = 808; shieldBottom = 200; shieldHalf = 264
        lockW = 272; lockH = 200; lockY = 336; lockR = 42
        shackleR = 84; shackleW = 52; shackleLeg = 40
    // 32 and 16 px are snapped to whole pixels (32 and 64 units per pixel)
    case .small:
        shieldTop = 800; shieldBottom = 192; shieldHalf = 288
        lockW = 320; lockH = 224; lockY = 320; lockR = 44
        shackleR = 96; shackleW = 64; shackleLeg = 32
    case .tiny:
        shieldTop = 832; shieldBottom = 192; shieldHalf = 320
        lockW = 384; lockH = 192; lockY = 320; lockR = 28
        shackleR = 96; shackleW = 64; shackleLeg = 64
    }
    let shield = shieldPath(cx: cx, top: shieldTop, bottom: shieldBottom, half: shieldHalf)

    // Shield: soft ambient shadow + tighter contact shadow under the foreground layer
    ctx.saveGState()
    shadow(-22, 48, color(0x031447, lod == .tiny ? 0 : lod == .small ? 0.3 : 0.45))
    ctx.addPath(shield); ctx.setFillColor(color(0xf4f8ff)); ctx.fillPath()
    ctx.restoreGState()
    if fine {
        ctx.saveGState()
        shadow(-5, 8, color(0x031447, 0.28))
        ctx.addPath(shield); ctx.setFillColor(color(0xf4f8ff)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Frosted glass face: white to a cool blue-grey
    fillGradient(shield, gradient([(color(0xffffff), 0), (color(0xf1f6ff), 0.45), (color(0xd3e1f8), 1)]),
                 from: CGPoint(x: cx - 120, y: shieldTop), to: CGPoint(x: cx + 80, y: shieldBottom))
    if fine {
        // Faint diagonal glass sheen over the upper-left
        ctx.saveGState(); ctx.addPath(shield); ctx.clip()
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: cx - shieldHalf - 10, y: 520))
        sheen.addCurve(to: CGPoint(x: cx + shieldHalf + 10, y: 700),
                       control1: CGPoint(x: cx - 120, y: 590), control2: CGPoint(x: cx + 120, y: 640))
        sheen.addLine(to: CGPoint(x: cx + shieldHalf + 10, y: shieldTop + 10))
        sheen.addLine(to: CGPoint(x: cx - shieldHalf - 10, y: shieldTop + 10))
        sheen.closeSubpath()
        ctx.addPath(sheen); ctx.clip()
        ctx.drawLinearGradient(gradient([(color(0xffffff, 0.75), 0), (color(0xffffff, 0.0), 1)]),
                               start: CGPoint(x: 0, y: shieldTop), end: CGPoint(x: 0, y: 560), options: [])
        ctx.restoreGState()
        // Glass edge: bright top rim, blue-tinted lower rim
        innerRim(shield, width: 6,
                 gradient([(color(0xffffff, 1), 0), (color(0xffffff, 0.3), 0.4), (color(0x8fb2ea, 0.55), 1)]),
                 top: shieldTop, bottom: shieldBottom)
    }

    // Lock
    let bodyRect = CGRect(x: cx - lockW / 2, y: lockY, width: lockW, height: lockH)
    let lockBody = smoothRect(bodyRect, radius: lockR)
    let shackleBase = bodyRect.maxY - 6
    let shackleCenterY = bodyRect.maxY + shackleLeg
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: cx - shackleR, y: shackleBase))
    shackle.addLine(to: CGPoint(x: cx - shackleR, y: shackleCenterY))
    shackle.addArc(center: CGPoint(x: cx, y: shackleCenterY), radius: shackleR, startAngle: .pi, endAngle: 0, clockwise: true)
    shackle.addLine(to: CGPoint(x: cx + shackleR, y: shackleBase))
    let shackleOutline = shackle.copy(strokingWithWidth: shackleW, lineCap: .butt, lineJoin: .round, miterLimit: 10)

    // Shadow the lock casts onto the shield
    ctx.saveGState()
    shadow(-12, 22, color(0x0a2a7a, fine ? 0.35 : 0))
    ctx.addPath(shackleOutline); ctx.addPath(lockBody)
    ctx.setFillColor(color(0x1a4fc8)); ctx.fillPath()
    ctx.restoreGState()

    // Shackle: brushed steel blue, lighter on the left
    ctx.saveGState(); ctx.addPath(shackleOutline); ctx.clip()
    ctx.drawLinearGradient(gradient([(color(0x6f9cf0), 0), (color(0x2f62d4), 0.5), (color(0x1c46b0), 1)]),
                           start: CGPoint(x: cx - shackleR - shackleW, y: 0), end: CGPoint(x: cx + shackleR + shackleW, y: 0), options: [])
    ctx.restoreGState()

    // Body: deep blue gradient with a glassy top highlight
    fillGradient(lockBody, gradient([(color(0x3d86ff), 0), (color(0x2160e6), 0.5), (color(0x1343bd), 1)]),
                 from: CGPoint(x: 0, y: bodyRect.maxY), to: CGPoint(x: 0, y: bodyRect.minY))
    if fine {
        ctx.saveGState(); ctx.addPath(lockBody); ctx.clip()
        ctx.drawLinearGradient(gradient([(color(0xffffff, 0.30), 0), (color(0xffffff, 0), 1)]),
                               start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.midY + 10), options: [])
        ctx.restoreGState()
        innerRim(lockBody, width: 4,
                 gradient([(color(0xffffff, 0.6), 0), (color(0xffffff, 0.08), 0.5), (color(0x061f6e, 0.4), 1)]),
                 top: bodyRect.maxY, bottom: bodyRect.minY)
    } else {
        innerRim(lockBody, width: lod == .tiny ? 0 : 12,
                 gradient([(color(0xffffff, 0.35), 0), (color(0xffffff, 0), 0.5)]),
                 top: bodyRect.maxY, bottom: bodyRect.minY)
    }

    // Keyhole in the "connected" green; a single dot at 32 px, omitted at 16 px
    let kc = CGPoint(x: cx, y: bodyRect.midY + lockH * 0.1)
    switch lod {
    case .full, .medium:
        let r: CGFloat = lod == .full ? 25 : 32, stem: CGFloat = lod == .full ? 22 : 32
        let keyhole = CGMutablePath()
        keyhole.addEllipse(in: CGRect(x: kc.x - r, y: kc.y - r, width: 2 * r, height: 2 * r))
        keyhole.addPath(smoothRect(CGRect(x: kc.x - stem / 2, y: kc.y - 74, width: stem, height: 74), radius: stem * 0.4))
        ctx.saveGState()
        shadow(0, 26, color(0x3cf08a, 0.55))
        ctx.addPath(keyhole); ctx.setFillColor(color(0x34d36e)); ctx.fillPath()
        ctx.restoreGState()
        fillGradient(keyhole, gradient([(color(0x7af5a8), 0), (color(0x2fd067), 0.55), (color(0x1fae52), 1)]),
                     from: CGPoint(x: 0, y: kc.y + r), to: CGPoint(x: 0, y: kc.y - 74))
    case .small:
        ctx.setFillColor(color(0x3ce07a))
        ctx.fillEllipse(in: CGRect(x: cx - 32, y: 416, width: 64, height: 64))
    case .tiny:
        break
    }

    return ctx.makeImage()!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(cgImage: render(px: px))
    let out = outDir.appendingPathComponent("icon_\(px)x\(px).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
}
print("wrote icons to \(outDir.path)")
