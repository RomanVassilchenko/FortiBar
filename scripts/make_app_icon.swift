#!/usr/bin/env swift
// Draws the FortiBar app icon (1024x1024 PNG with alpha) and writes the other sizes with sips.
//
//     swift scripts/make_app_icon.swift FortiBar/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Body: the macOS icon grid leaves 100pt around an 824pt squircle
let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.38))
ctx.addPath(body)
ctx.setFillColor(color(0x1456d6))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(body)
ctx.clip()
ctx.drawLinearGradient(gradient([(color(0x4a97ff), 0), (color(0x1b62e0), 0.55), (color(0x0b3a9c), 1)]),
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// Soft glass sheen over the upper half
ctx.drawLinearGradient(gradient([(color(0xffffff, 0.28), 0), (color(0xffffff, 0), 1)]),
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 520), options: [])
ctx.restoreGState()

ctx.addPath(body)
ctx.setStrokeColor(color(0xffffff, 0.3))
ctx.setLineWidth(3)
ctx.strokePath()

// Shield
let cx: CGFloat = 512, top: CGFloat = 790, bottom: CGFloat = 226, half: CGFloat = 232
let shoulder = top - 56
let shield = CGMutablePath()
shield.move(to: CGPoint(x: cx, y: top))
shield.addCurve(to: CGPoint(x: cx + half, y: shoulder), control1: CGPoint(x: cx + 150, y: top), control2: CGPoint(x: cx + half, y: top))
shield.addLine(to: CGPoint(x: cx + half, y: 520))
shield.addCurve(to: CGPoint(x: cx, y: bottom), control1: CGPoint(x: cx + half, y: 360), control2: CGPoint(x: cx + 120, y: 270))
shield.addCurve(to: CGPoint(x: cx - half, y: 520), control1: CGPoint(x: cx - 120, y: 270), control2: CGPoint(x: cx - half, y: 360))
shield.addLine(to: CGPoint(x: cx - half, y: shoulder))
shield.addCurve(to: CGPoint(x: cx, y: top), control1: CGPoint(x: cx - half, y: top), control2: CGPoint(x: cx - 150, y: top))
shield.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x021a52, 0.45))
ctx.addPath(shield)
ctx.setFillColor(color(0xffffff))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shield)
ctx.clip()
ctx.drawLinearGradient(gradient([(color(0xffffff), 0), (color(0xd9e6fb), 1)]),
                       start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
ctx.restoreGState()

// Lock: shackle behind, body in front
let lockBlue = color(0x1553d0)
ctx.setStrokeColor(lockBlue)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: cx, y: 572), radius: 62, startAngle: 0, endAngle: .pi, clockwise: false)
ctx.move(to: CGPoint(x: cx - 62, y: 572)); ctx.addLine(to: CGPoint(x: cx - 62, y: 520))
ctx.move(to: CGPoint(x: cx + 62, y: 572)); ctx.addLine(to: CGPoint(x: cx + 62, y: 520))
ctx.strokePath()

let lockBody = CGPath(roundedRect: CGRect(x: cx - 112, y: 372, width: 224, height: 170), cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.saveGState()
ctx.addPath(lockBody)
ctx.clip()
ctx.drawLinearGradient(gradient([(color(0x2f78f0), 0), (color(0x0f3fae), 1)]),
                       start: CGPoint(x: 0, y: 542), end: CGPoint(x: 0, y: 372), options: [])
ctx.restoreGState()

// Keyhole in the "connected" green
ctx.setFillColor(color(0x34d767))
ctx.fillEllipse(in: CGRect(x: cx - 24, y: 466, width: 48, height: 48))
ctx.fill(CGRect(x: cx - 11, y: 408, width: 22, height: 70))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let master = outDir.appendingPathComponent("icon_1024x1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

for px in [16, 32, 64, 128, 256, 512] {
    let out = outDir.appendingPathComponent("icon_\(px)x\(px).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", out.path]
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
}
print("wrote icons to \(outDir.path)")
