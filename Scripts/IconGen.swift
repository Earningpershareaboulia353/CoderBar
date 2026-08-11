import AppKit
import CoreGraphics
import Foundation

// Renders the app icon set: rounded-square gradient tile with a white
// "island arc + waveform" mark (references the original app's motif).
// Output: <outdir>/icon_*.png  (iconutil-ready)

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/coderbaricon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    let radius = CGFloat(px) * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // gradient background (deep indigo -> violet, mirrors original's purple family)
    let colors = [
        NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.45, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.48, green: 0.23, blue: 0.75, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.80, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: CGFloat(px)),
                           end: CGPoint(x: CGFloat(px), y: 0),
                           options: [])

    // subtle vertical sheen
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
    ctx.fill(CGRect(x: 0, y: CGFloat(px) * 0.72, width: CGFloat(px), height: CGFloat(px) * 0.28))
    ctx.restoreGState()

    let s = CGFloat(px)
    let line: CGFloat = max(1, s * 0.045)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(line)
    ctx.setLineCap(.square)
    ctx.setLineJoin(.round)
    ctx.setAlpha(0.95)

    // "island" arc
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: s * 0.5, y: s * 0.42),
               radius: s * 0.30,
               startAngle: 0,
               endAngle: .pi,
               clockwise: true)
    ctx.addPath(arc)
    ctx.strokePath()

    // rising waveform (three ascending bars) — "activity" motif
    let bars: [(CGFloat, CGFloat)] = [
        (s * 0.22, s * 0.14),
        (s * 0.35, s * 0.20),
        (s * 0.48, s * 0.26),
    ]
    ctx.setAlpha(0.95)
    for (x, h) in bars {
        let r = CGRect(x: x, y: s * 0.30, width: s * 0.085, height: h)
        let barPath = CGPath(roundedRect: r, cornerWidth: r.width / 2, cornerHeight: r.width / 2, transform: nil)
        ctx.addPath(barPath)
    }
    ctx.strokePath()

    // status dot
    ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.65, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: s * 0.62, y: s * 0.66, width: s * 0.11, height: s * 0.11))

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png render failed")
    }
    try! png.write(to: url)
}

let specs: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for spec in specs {
    let image = render(spec.px)
    writePNG(image, to: URL(fileURLWithPath: "\(outDir)/\(spec.name)"))
    print("wrote \(spec.name) (\(spec.px)px)")
}