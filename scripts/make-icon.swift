import AppKit

// Draws the Rowster app icon (a data grid with one highlighted row on an indigo-to-teal tile)
// into the given AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift Rowster/Resources/Assets.xcassets/AppIcon.appiconset [icon.png]
// The optional second argument also writes a 512 px copy (used by the README).
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawGrid() {
    let card = NSRect(x: 232, y: 262, width: 560, height: 500)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 56, yRadius: 56)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    color(1, 1, 1).setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    cardPath.addClip()

    // Header row.
    let rowHeight: CGFloat = 100
    let header = NSRect(x: card.minX, y: card.maxY - rowHeight, width: card.width, height: rowHeight)
    NSGradient(starting: color(0.20, 0.22, 0.45), ending: color(0.27, 0.30, 0.58))!.draw(in: header, angle: 90)

    // Body rows, one highlighted like a pending change.
    for row in 0..<4 {
        let rect = NSRect(x: card.minX, y: card.maxY - rowHeight * CGFloat(row + 2), width: card.width, height: rowHeight)
        if row == 1 {
            NSGradient(starting: color(1.0, 0.80, 0.30), ending: color(1.0, 0.62, 0.22))!.draw(in: rect, angle: 0)
        } else {
            (row % 2 == 0 ? color(1, 1, 1) : color(0.95, 0.96, 0.99)).setFill()
            rect.fill()
        }
    }

    // Cell placeholders.
    let columns: [(x: CGFloat, width: CGFloat)] = [(44, 96), (196, 170), (410, 106)]
    for row in 0..<5 {
        let y = card.maxY - rowHeight * CGFloat(row + 1) + 36
        for (index, column) in columns.enumerated() {
            let shrink = CGFloat((row * 3 + index * 5) % 4) * 14
            let pill = NSRect(x: card.minX + column.x, y: y, width: column.width - shrink, height: 28)
            let fill: NSColor
            switch row {
            case 0: fill = color(1, 1, 1, 0.85)
            case 2: fill = color(0.35, 0.20, 0.05, 0.70)
            default: fill = color(0.27, 0.30, 0.58, index == 0 ? 0.55 : 0.28)
            }
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
        }
    }

    // Column separators.
    color(0.20, 0.22, 0.45, 0.10).setFill()
    for x in [card.minX + 168, card.minX + 384] {
        NSRect(x: x, y: card.minY, width: 4, height: card.height - rowHeight).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.36, 0.30, 0.86), ending: color(0.06, 0.66, 0.70))!.draw(in: body, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    color(1, 1, 1, 0.10).setFill()
    NSBezierPath(ovalIn: NSRect(x: 420, y: 520, width: 760, height: 760)).fill()
    NSGraphicsContext.restoreGraphicsState()

    drawGrid()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for variant in variants {
    let suffix = variant.scale == 2 ? "@2x" : ""
    let filename = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try render(pixels: variant.points * variant.scale).write(to: output.appendingPathComponent(filename))
    images.append(["size": "\(variant.points)x\(variant.points)", "idiom": "mac", "filename": filename, "scale": "\(variant.scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
if CommandLine.arguments.count > 2 {
    try render(pixels: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("AppIcon written to \(output.path)")
