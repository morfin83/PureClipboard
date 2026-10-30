#!/usr/bin/env swift
// Builds the web graphics from real screenshots of the app (see `PureClipboard --render-screenshots DIR`).
//   swift scripts/make-web-assets.swift SHOTS_DIR OUT_DIR
// Produces: hero-preview.png, og-image.png, history-on.png, history-off.png, clipboard.png (cropped screenshots).
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("Použití: make-web-assets.swift SHOTS_DIR OUT_DIR\n".utf8)); exit(2) }
let shots = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let paper = NSColor(red: 0.980, green: 0.980, blue: 0.973, alpha: 1)      // #FAFAF8
let ink = NSColor(red: 0.137, green: 0.145, blue: 0.133, alpha: 1)        // #232522
let muted = NSColor(red: 0.392, green: 0.396, blue: 0.376, alpha: 1)      // #646560
let purple = NSColor(red: 0.42, green: 0.27, blue: 0.85, alpha: 1)

func load(_ name: String) -> NSBitmapImageRep { NSBitmapImageRep(data: try! Data(contentsOf: shots.appendingPathComponent(name)))! }
func crop(_ rep: NSBitmapImageRep, top: Int, height: Int) -> NSBitmapImageRep {
    let h = min(height, rep.pixelsHigh - top)
    let cg = rep.cgImage!.cropping(to: CGRect(x: 0, y: top, width: rep.pixelsWide, height: h))!
    return NSBitmapImageRep(cgImage: cg)
}
func save(_ rep: NSBitmapImageRep, _ name: String) { try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name)) }
func canvas(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func text(_ s: String, _ p: NSPoint, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]).draw(at: p)
}
/// Draws a screenshot as a window with rounded corners and a soft shadow.
func window(_ rep: NSBitmapImageRep, in rect: NSRect) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowBlurRadius = 60; shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    NSColor(white: 0.05, alpha: 1).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSImage(cgImage: rep.cgImage!, size: rep.size == .zero ? NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) : rep.size).draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

let on = load("app-history-on.png"), off = load("app-history-off.png"), clip = load("app-clipboard.png")
save(on, "history-on.png"); save(off, "history-off.png"); save(crop(clip, top: 0, height: 1560), "clipboard.png")   // top cards only: lower cards show local file paths
save(crop(on, top: 0, height: 1900), "app-preview.png")

// Hero: light surface, headline, dark app preview (history, cropped to the top part).
let heroShot = crop(on, top: 0, height: 1500)
save(canvas(2400, 1500) {
    paper.setFill(); NSRect(x: 0, y: 0, width: 2400, height: 1500).fill()
    text("PURE / LAB", NSPoint(x: 140, y: 1300), 30, .semibold, purple, kern: 6)
    text("Pure Clipboard.", NSPoint(x: 140, y: 1110), 124, .bold, ink)
    text("Historie schránky na vašem Macu.", NSPoint(x: 140, y: 1010), 56, .regular, muted)
    text("Vypnutá, dokud ji nezapnete. Nic neodchází do cloudu.", NSPoint(x: 140, y: 930), 38, .regular, muted)
    let w: CGFloat = 960, h = w * CGFloat(heroShot.pixelsHigh) / CGFloat(heroShot.pixelsWide)
    window(heroShot, in: NSRect(x: 1280, y: 1500 - h - 90, width: w, height: h))
    text("Snímek skutečné aplikace s ukázkovými daty.", NSPoint(x: 140, y: 90), 28, .regular, muted)
}, "hero-preview.png")

// Social preview 1200×630.
save(canvas(1200, 630) {
    paper.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 630).fill()
    text("PURE / LAB", NSPoint(x: 70, y: 520), 18, .semibold, purple, kern: 4)
    text("Pure Clipboard.", NSPoint(x: 70, y: 400), 70, .bold, ink)
    text("Historie schránky pro macOS.", NSPoint(x: 70, y: 335), 34, .regular, muted)
    text("Soukromě, lokálně, na váš pokyn.", NSPoint(x: 70, y: 285), 26, .regular, muted)
    let shot = crop(on, top: 0, height: 1000)
    let w: CGFloat = 480, h = w * CGFloat(shot.pixelsHigh) / CGFloat(shot.pixelsWide)
    window(shot, in: NSRect(x: 660, y: (630 - h) / 2, width: w, height: h))
}, "og-image.png")
print("hotovo:", out.path)
