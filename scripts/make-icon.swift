import AppKit

// Draws the Rowster app icon (a white row stepping out of a frosted-glass grid, on an indigo → raspberry →
// amber tile) into the given AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift Rowster/Resources/Assets.xcassets/AppIcon.appiconset [icon.png]
// The optional second argument also writes a 512 px copy (used by the README).
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let locations: [CGFloat] = [0, 0.55, 1]
let signature = NSGradient(
    colors: [color(hex: 0x5B3FE6), color(hex: 0xC42A73), color(hex: 0xF59E42)], atLocations: locations,
    colorSpace: .sRGB)!

func pill(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 32) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2)
}

func drawGrid() {
    // The glass grid.
    let card = NSBezierPath(roundedRect: NSRect(x: 256, y: 280, width: 512, height: 464), xRadius: 80, yRadius: 80)
    color(hex: 0xFFFFFF, alpha: 0.16).setFill()
    card.fill()
    color(hex: 0xFFFFFF, alpha: 0.5).setStroke()
    card.lineWidth = 6
    card.stroke()

    // The rows that stay in the grid.
    color(hex: 0xFFFFFF, alpha: 0.75).setFill()
    for (x, width) in [(324, 112), (464, 236)] as [(CGFloat, CGFloat)] { pill(x: x, y: 624, width: width).fill() }
    for (x, width) in [(324, 112), (464, 192)] as [(CGFloat, CGFloat)] { pill(x: x, y: 368, width: width).fill() }

    // The row that steps out, white and lifted.
    let row = NSBezierPath(roundedRect: NSRect(x: 196, y: 452, width: 632, height: 120), xRadius: 60, yRadius: 60)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(hex: 0x2A0A3A, alpha: 0.45)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -28)
    shadow.set()
    NSColor.white.setFill()
    row.fill()
    NSGraphicsContext.restoreGraphicsState()

    for (x, width) in [(284, 112), (424, 272)] as [(CGFloat, CGFloat)] {
        signature.draw(in: pill(x: x, y: 496, width: width), angle: 0)
    }
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
    shadow.shadowColor = color(hex: 0x1A0B2E, alpha: 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    signature.draw(in: body, angle: -45)
    NSGradient(starting: color(hex: 0xFFFFFF, alpha: 0.35), ending: color(hex: 0xFFFFFF, alpha: 0))!
        .draw(in: body, relativeCenterPosition: NSPoint(x: -0.5, y: 0.7))

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
