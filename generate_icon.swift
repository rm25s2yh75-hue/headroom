import CoreGraphics
import AppKit
import Foundation

func drawIcon(ctx: CGContext, size: Int) {
    let s   = CGFloat(size)
    let bg  = CGColor(red: 0.07, green: 0.08, blue: 0.14, alpha: 1.0)
    let dot = CGColor(red: 0.30, green: 0.78, blue: 0.46, alpha: 1.0) // matches menu bar dot

    // Dark rounded background
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                       cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil))
    ctx.setFillColor(bg); ctx.fillPath()

    // Green dot centred, ~60% of icon size
    let dotDiameter = s * 0.60
    let dotX = (s - dotDiameter) / 2
    let dotY = (s - dotDiameter) / 2
    ctx.addEllipse(in: CGRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter))
    ctx.setFillColor(dot); ctx.fillPath()

    // Subtle inner highlight to give the dot some depth
    let highlightSize = dotDiameter * 0.42
    let highlightX = dotX + dotDiameter * 0.22
    let highlightY = dotY + dotDiameter * 0.44
    ctx.addEllipse(in: CGRect(x: highlightX, y: highlightY, width: highlightSize, height: highlightSize))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.fillPath()

    // placeholder to satisfy compiler — no arrow needed
    let _ = CGColor(red: 0.22, green: 0.85, blue: 0.48, alpha: 0.75)
    ctx.fillPath()
}

func makeIconPNG(size: Int) -> Data? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    drawIcon(ctx: ctx, size: size)
    guard let cgImage = ctx.makeImage() else { return nil }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    guard let tiff = nsImage.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:]) else { return nil }
    return png
}

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in entries {
    if let data = makeIconPNG(size: size) {
        try? data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }
}
print("Iconset written to \(iconsetPath)")
