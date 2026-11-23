#!/usr/bin/env swift
// Draws the 1280x640 social preview (GitHub repository card, link previews).
//
//     swift scripts/make_social_preview.swift FortiBar/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png docs/assets/social-preview.png
//
// The app icon is read from the appiconset so the card always matches the current logo.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make_social_preview.swift <icon 1024 png> <output png>\n".utf8))
    exit(2)
}

let width = 1280, height = 640
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha,
    ])!
}

// Background: the icon's midnight blue, lighter in the top-left corner
let bg = CGGradient(colorsSpace: space, colors: [color(0x2b49b8), color(0x14217a), color(0x0a1040)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])

// Soft glow behind the icon
let glow = CGGradient(colorsSpace: space, colors: [color(0x6f8dff, 0.35), color(0x6f8dff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 320), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 320), endRadius: 360, options: [])

let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = gc

// Icon (the 1024 canvas has transparent padding around the squircle, so draw it larger than it looks)
icon.draw(in: NSRect(x: 100, y: 100, width: 460, height: 460), from: .zero, operation: .sourceOver, fraction: 1)

func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color c: NSColor, kern: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c, .kern: kern]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

let left: CGFloat = 610
draw("FortiBar", at: CGPoint(x: left, y: 320), size: 128, weight: .bold, color: .white, kern: -2)
draw("FortiVPN in your Mac's menu bar", at: CGPoint(x: left + 4, y: 262), size: 38, weight: .medium,
     color: NSColor(cgColor: color(0xcfd9ff))!)
draw("Several tunnels  ·  Auto-reconnect  ·  Keychain  ·  CLI", at: CGPoint(x: left + 4, y: 205), size: 26, weight: .regular,
     color: NSColor(cgColor: color(0x9fb2f0))!)

// Green "connected" dot, like the one in the logo
ctx.setFillColor(color(0x34d46b))
ctx.fillEllipse(in: CGRect(x: left + 6, y: 150, width: 22, height: 22))
draw("Open source  ·  macOS 13+  ·  Built on openfortivpn", at: CGPoint(x: left + 42, y: 147), size: 24, weight: .medium,
     color: NSColor(cgColor: color(0xcfd9ff))!)

guard let cg = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
