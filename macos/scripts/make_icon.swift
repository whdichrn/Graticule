import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    // macOS squircle padding
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Deep scientific ocean-to-teal background gradient
    let bgColors = [
        CGColor(red: 0.04, green: 0.14, blue: 0.34, alpha: 1.0),
        CGColor(red: 0.06, green: 0.34, blue: 0.58, alpha: 1.0),
        CGColor(red: 0.09, green: 0.56, blue: 0.68, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )
    }

    // Stylized globe / graticule motif
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let radius = rect.width * 0.33

    // Warm thermal data band inside globe
    ctx.saveGState()
    let globePath = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    ctx.addPath(globePath)
    ctx.clip()

    let dataColors = [
        CGColor(red: 0.08, green: 0.28, blue: 0.64, alpha: 0.9),
        CGColor(red: 0.16, green: 0.72, blue: 0.68, alpha: 0.85),
        CGColor(red: 0.96, green: 0.76, blue: 0.28, alpha: 0.9),
        CGColor(red: 0.88, green: 0.32, blue: 0.22, alpha: 0.9)
    ] as CFArray
    if let dataGrad = CGGradient(colorsSpace: colorSpace, colors: dataColors, locations: [0.0, 0.38, 0.72, 1.0]) {
        ctx.drawLinearGradient(
            dataGrad,
            start: CGPoint(x: center.x - radius, y: center.y - radius * 0.7),
            end: CGPoint(x: center.x + radius, y: center.y + radius * 0.8),
            options: []
        )
    }

    // Meridians and parallels
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
    ctx.setLineWidth(max(1.0, s * 0.012))
    for factor in [-0.45, 0.0, 0.45] {
        let y = center.y + radius * CGFloat(factor)
        let halfW = sqrt(max(0, radius * radius - pow(y - center.y, 2)))
        ctx.move(to: CGPoint(x: center.x - halfW, y: y))
        ctx.addLine(to: CGPoint(x: center.x + halfW, y: y))
    }
    ctx.strokePath()

    for xScale in [0.42, 0.76] {
        let rx = radius * CGFloat(xScale)
        ctx.strokeEllipse(in: CGRect(x: center.x - rx, y: center.y - radius, width: rx * 2, height: radius * 2))
    }
    ctx.move(to: CGPoint(x: center.x, y: center.y - radius))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + radius))
    ctx.strokePath()
    ctx.restoreGState()

    // Crisp white globe rim
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.setLineWidth(max(1.5, s * 0.02))
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

    ctx.restoreGState()

    // Outer subtle rim highlight
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(max(1.0, s * 0.01))
    ctx.addPath(squircle)
    ctx.strokePath()

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
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

for (filename, size) in specs {
    if let png = renderIcon(pixelSize: size) {
        try png.write(to: iconsetDir.appendingPathComponent(filename))
    }
}
