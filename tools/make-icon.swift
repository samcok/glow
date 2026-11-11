// Draws the Glow app icon (1024x1024 PNG). Usage: swift tools/make-icon.swift out.png
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
func radial(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [rgb(hex, a), rgb(hex, a * 0.35), rgb(hex, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

// macOS icon grid: 824pt rounded square (~22% radius), centred
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 824 * 0.22, cornerHeight: 824 * 0.22, transform: nil))
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x171A24), rgb(0x262B3C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])  // y up: lighter at top
// light bloom: three overlapping soft radial gradients
ctx.setBlendMode(.plusLighter)
radial(CGPoint(x: 440, y: 450), 300, 0xFFB547, 0.85)
radial(CGPoint(x: 590, y: 470), 290, 0xE8508A, 0.75)
radial(CGPoint(x: 515, y: 600), 280, 0x4F7BFF, 0.8)
ctx.setBlendMode(.normal)
radial(CGPoint(x: 512, y: 520), 90, 0xFFFFFF, 1)
ctx.restoreGState()

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
