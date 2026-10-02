#!/usr/bin/env swift
// Renders the iPhone app icon: the shared horseshoe-magnet artwork from
// linux/flinger/assets/tray-idle.svg, drawn at 1024px over a gradient. The
// SVG is tiny (one path, two rects), so the geometry is transcribed here
// rather than parsed — if the tray artwork changes shape, update both.
//
//   swift ios/make-icon.swift            # writes the PNG into the asset catalog
//
// iOS masks icons itself, so the output is a full-bleed opaque square.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "ios/TorrentFlingerPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background: a deep blue gradient, light at the top-left.
let gradient = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(srgbRed: 0.22, green: 0.42, blue: 0.86, alpha: 1),
        CGColor(srgbRed: 0.09, green: 0.16, blue: 0.42, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

// The SVG lives in a 16-unit box with y pointing down; map it onto the
// bitmap (y up) with a little breathing room — the tray fills 82% of its
// box because it competes with system glyphs, an app icon doesn't.
let inset: CGFloat = 1.6
let scale = CGFloat(size) / (16 + inset * 2)
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: scale, y: -scale)
ctx.translateBy(x: inset, y: inset)

// Shadow under the magnet so it lifts off the gradient.
ctx.setShadow(offset: CGSize(width: 0, height: -0.35), blur: 0.9,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))

// Arch: M3.2 11 L3.2 5.6 Q3.2 2.4 8 2.4 Q12.8 2.4 12.8 5.6 L12.8 11
let arch = CGMutablePath()
arch.move(to: CGPoint(x: 3.2, y: 11))
arch.addLine(to: CGPoint(x: 3.2, y: 5.6))
arch.addQuadCurve(to: CGPoint(x: 8, y: 2.4), control: CGPoint(x: 3.2, y: 2.4))
arch.addQuadCurve(to: CGPoint(x: 12.8, y: 5.6), control: CGPoint(x: 12.8, y: 2.4))
arch.addLine(to: CGPoint(x: 12.8, y: 11))
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(2.8)
ctx.setLineCap(.butt)
ctx.addPath(arch)
ctx.strokePath()

// Pole faces: the classic magnet's painted tips.
ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.33, blue: 0.36, alpha: 1))
ctx.fill(CGRect(x: 1.1, y: 11, width: 4.2, height: 3.2))
ctx.fill(CGRect(x: 10.7, y: 11, width: 4.2, height: 3.2))

let image = ctx.makeImage()!
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("failed to write \(out.path)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(out.path)")
