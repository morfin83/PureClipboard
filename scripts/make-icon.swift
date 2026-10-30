// Generates the Pure Clipboard app icon (PureStudio style: dark base, teal accent) as an .iconset.
// Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-icon.swift <out.iconset> [preview.png]
// Then:  iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: make-icon.swift <out.iconset> [preview.png]\n".utf8))
    exit(2)
}
let iconsetURL = URL(fileURLWithPath: arguments[1])
let previewURL = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil

let accent = NSColor(srgbRed: 0.20, green: 0.84, blue: 0.78, alpha: 1)
let accentDeep = NSColor(srgbRed: 0.10, green: 0.55, blue: 0.56, alpha: 1)

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    let cg = context.cgContext
    cg.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824 pt rounded square centred in 1024 pt.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

    // Soft shadow under the plate.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor.black.setFill()
    path.fill()
    cg.restoreGState()

    // Dark base gradient.
    cg.saveGState()
    path.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.095, green: 0.125, blue: 0.150, alpha: 1),
                        NSColor(srgbRed: 0.030, green: 0.040, blue: 0.055, alpha: 1)])!
        .draw(in: plate, angle: -90)
    // Teal glow rising from the lower left, very subtle.
    NSGradient(colors: [accent.withAlphaComponent(0.20), accent.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 330, y: 300), radius: 0, toCenter: NSPoint(x: 330, y: 300), radius: 520, options: [])
    cg.restoreGState()

    // Hairline border.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let border = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5, dy: 1.5), xRadius: 184.5, yRadius: 184.5)
    border.lineWidth = 3
    border.stroke()

    // Clipboard glyph, tinted with an accent gradient.
    let configuration = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let glyphSize = symbol.size
        let glyphRect = NSRect(
            x: plate.midX - glyphSize.width / 2, y: plate.midY - glyphSize.height / 2 - 6,
            width: glyphSize.width, height: glyphSize.height)

        let tinted = NSImage(size: glyphSize)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: glyphSize))
        NSGradient(colors: [accent, accentDeep])!
            .draw(in: NSRect(origin: .zero, size: glyphSize), angle: -60)
        tinted.unlockFocus()

        // The gradient above is drawn over the symbol; keep only the symbol's shape.
        let masked = NSImage(size: glyphSize)
        masked.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: glyphSize))
        tinted.draw(in: NSRect(origin: .zero, size: glyphSize), from: .zero, operation: .sourceIn, fraction: 1)
        masked.unlockFocus()

        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 40, color: accent.withAlphaComponent(0.55).cgColor)
        masked.draw(in: glyphRect)
        cg.restoreGState()
    }
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try! data.write(to: url)
}

try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
let master = render(size: 1024)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in entries {
    writePNG(size == 1024 ? master : render(size: size), to: iconsetURL.appendingPathComponent(name))
}
if let previewURL { writePNG(master, to: previewURL) }
print("Wrote \(entries.count) icons to \(iconsetURL.path)")
