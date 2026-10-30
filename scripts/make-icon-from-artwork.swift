// Builds the Pure Clipboard app icon from the supplied artwork (Resources/Artwork/AppIcon-source.png)
// as an .iconset: the artwork's own rounded plate is cropped out and placed on the macOS icon grid
// (824 pt plate centred in 1024 pt, transparent margin, soft shadow).
// Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-icon-from-artwork.swift <artwork.png> <out.iconset> [preview.png]
// Then:  iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("Usage: make-icon-from-artwork.swift <artwork.png> <out.iconset> [preview.png]\n".utf8))
    exit(2)
}
guard let artwork = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])),
      let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("Cannot read artwork\n".utf8))
    exit(1)
}
let iconsetURL = URL(fileURLWithPath: arguments[2])
let previewURL = arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : nil

// Plate of the 1254 px artwork (measured: left/right 136/1118, top/bottom 106/1072, corner radius ≈ 200 px).
let plateInSource = CGRect(x: 136, y: 106, width: 982, height: 966)
let cornerInSource: CGFloat = 200
guard let plateImage = source.cropping(to: plateInSource) else { exit(1) }

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius = cornerInSource * plate.width / plateInSource.width
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    cg.addPath(path)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.interpolationQuality = .high
    cg.draw(plateImage, in: plate)
    cg.restoreGState()
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
