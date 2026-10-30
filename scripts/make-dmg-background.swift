#!/usr/bin/env swift
// Draws the background of the installer disk image (660 × 400 pt, @2x) in the PURE style:
// light surface, purple accent, an arrow from the app to Applications.
//   swift scripts/make-dmg-background.swift out.png "Přetáhněte do složky Applications" "Ad-hoc podpis · testovací sestavení"
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("Použití: make-dmg-background.swift out.png [nadpis] [poznámka]\n".utf8)); exit(2) }
let title = args.count > 2 ? args[2] : "Přetáhněte do složky Applications"
let note = args.count > 3 ? args[3] : ""

let size = NSSize(width: 660, height: 400)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let purple = NSColor(red: 0.42, green: 0.27, blue: 0.85, alpha: 1)
NSColor(red: 0.972, green: 0.969, blue: 0.985, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
NSGradient(colors: [purple.withAlphaComponent(0.10), purple.withAlphaComponent(0)])?
    .draw(in: NSRect(x: 0, y: 160, width: size.width, height: 240), angle: 90)

func text(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0, centered: Bool = false) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
    let str = NSAttributedString(string: s, attributes: attrs)
    let origin = centered ? NSPoint(x: p.x - str.size().width / 2, y: p.y) : p
    str.draw(at: origin)
}
text("PURESTUDIO", at: NSPoint(x: 330, y: 352), size: 11, weight: .semibold, color: purple, kern: 3, centered: true)
text("Pure Clipboard", at: NSPoint(x: 330, y: 318), size: 26, weight: .semibold, color: NSColor(white: 0.1, alpha: 1), centered: true)
text(title, at: NSPoint(x: 330, y: 62), size: 14, weight: .medium, color: NSColor(white: 0.3, alpha: 1), centered: true)
if !note.isEmpty { text(note, at: NSPoint(x: 330, y: 36), size: 11, weight: .medium, color: NSColor(red: 0.75, green: 0.4, blue: 0.05, alpha: 1), centered: true) }

// Arrow between the two icon positions (170,185) and (490,185).
let arrow = NSBezierPath()
arrow.lineWidth = 3.5
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 252, y: 190)); arrow.line(to: NSPoint(x: 408, y: 190))
purple.withAlphaComponent(0.75).setStroke(); arrow.stroke()
let head = NSBezierPath()
head.lineWidth = 3.5; head.lineCapStyle = .round; head.lineJoinStyle = .round
head.move(to: NSPoint(x: 392, y: 206)); head.line(to: NSPoint(x: 410, y: 190)); head.line(to: NSPoint(x: 392, y: 174))
head.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
