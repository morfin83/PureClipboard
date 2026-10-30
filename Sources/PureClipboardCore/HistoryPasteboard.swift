import AppKit
import Foundation
import PDFKit
import Vision

/// Reads a `PasteboardSnapshot` from a pasteboard, with size guards so a huge copy cannot exhaust memory.
public enum PasteboardReader {
    /// Anything above this is not even read (the per-item limit is applied later).
    public static let hardReadLimit = 64 * 1_048_576

    public static func snapshot(of pasteboard: NSPasteboard, sourceApp: String? = nil) -> PasteboardSnapshot {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        var snapshot = PasteboardSnapshot(changeCount: pasteboard.changeCount, types: types, sourceApp: sourceApp)
        if PasteboardMarkers.isMarkedPrivate(types) { return snapshot }

        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        snapshot.fileURLs = urls.map(\.standardizedFileURL)
        if !snapshot.fileURLs.isEmpty { return snapshot }

        snapshot.text = pasteboard.string(forType: .string)
        snapshot.rtf = pasteboard.data(forType: .rtf).flatMap { $0.count <= hardReadLimit ? $0 : nil }
        if snapshot.text == nil, snapshot.rtf == nil {
            snapshot.pdf = pasteboard.data(forType: .pdf).flatMap { $0.count <= hardReadLimit ? $0 : nil }
            if snapshot.pdf == nil {
                let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
                if let raw, raw.count <= hardReadLimit { snapshot.image = pngData(from: raw) }
            }
        }
        return snapshot
    }

    /// Normalises TIFF/PNG to PNG so the same picture always hashes the same.
    public static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

public struct RestoreOutcome: Equatable, Sendable {
    public enum Result: Equatable, Sendable { case restored, partial(missing: Int), failed(String) }
    public var result: Result
    /// Pasteboard change count after our write, so the monitor can ignore it.
    public var changeCount: Int
}

/// Puts a stored item back on a pasteboard (the general one in the app, a private one in tests).
public enum PasteboardRestorer {
    public static func restore(
        _ item: HistoryItem, from store: HistoryStore, to pasteboard: NSPasteboard,
        claims: ClipboardClaimStore? = nil
    ) -> RestoreOutcome {
        func write() -> RestoreOutcome {
            do {
                switch item.kind {
                case .text:
                    let text = String(decoding: try store.data(for: item, role: "text"), as: UTF8.self)
                    pasteboard.clearContents()
                    guard pasteboard.setString(text, forType: .string) else { return fail(pasteboard, "zápis do schránky selhal") }
                    return RestoreOutcome(result: .restored, changeCount: pasteboard.changeCount)
                case .richText:
                    let text = String(decoding: try store.data(for: item, role: "text"), as: UTF8.self)
                    let rtf = try store.data(for: item, role: "rtf")
                    pasteboard.clearContents()
                    guard pasteboard.setData(rtf, forType: .rtf), pasteboard.setString(text, forType: .string) else {
                        return fail(pasteboard, "zápis do schránky selhal")
                    }
                    return RestoreOutcome(result: .restored, changeCount: pasteboard.changeCount)
                case .image:
                    let png = try store.data(for: item, role: "image")
                    pasteboard.clearContents()
                    guard pasteboard.setData(png, forType: .png) else { return fail(pasteboard, "zápis do schránky selhal") }
                    return RestoreOutcome(result: .restored, changeCount: pasteboard.changeCount)
                case .pdf:
                    let pdf = try store.data(for: item, role: "pdf")
                    pasteboard.clearContents()
                    guard pasteboard.setData(pdf, forType: .pdf) else { return fail(pasteboard, "zápis do schránky selhal") }
                    return RestoreOutcome(result: .restored, changeCount: pasteboard.changeCount)
                case .files:
                    var urls: [URL] = []
                    var missing = 0
                    for ref in item.files ?? [] {
                        switch ref.resolve() {
                        case .available: urls.append(URL(fileURLWithPath: ref.path))
                        case .moved(let path): urls.append(URL(fileURLWithPath: path))
                        case .missing: missing += 1
                        }
                    }
                    // Nothing is changed when no original exists any more.
                    guard !urls.isEmpty else { return RestoreOutcome(result: .failed("Originály už neexistují; schránka zůstala beze změny."), changeCount: pasteboard.changeCount) }
                    pasteboard.clearContents()
                    guard pasteboard.writeObjects(urls as [NSURL]) else { return fail(pasteboard, "zápis do schránky selhal") }
                    return RestoreOutcome(result: missing == 0 ? .restored : .partial(missing: missing), changeCount: pasteboard.changeCount)
                }
            } catch {
                return fail(pasteboard, error.localizedDescription)
            }
        }
        guard let claims else { return write() }
        return claims.withLock {
            let outcome = write()
            if outcome.result == .restored || { if case .partial = outcome.result { true } else { false } }() {
                claims.record(.init(source: "history", session: "history-restore", time: Date()))
            }
            return outcome
        } ?? RestoreOutcome(result: .failed("Schránku právě používá jiný proces."), changeCount: pasteboard.changeCount)
    }

    private static func fail(_ pasteboard: NSPasteboard, _ message: String) -> RestoreOutcome {
        RestoreOutcome(result: .failed(message), changeCount: pasteboard.changeCount)
    }
}

/// On-device OCR (Vision) and PDF text-layer scan. It cannot find every secret: handwriting, QR codes, tiny or
/// low-contrast text, and anything that is not text at all (faces, documents photographed at an angle) pass through.
public struct VisionContentScreener: ContentScreener {
    public static let maxPDFPages = 200
    public static let ocrPDFPages = 5

    public init() {}

    public func screen(imagePNG: Data) -> ScreeningResult {
        guard let rep = NSBitmapImageRep(data: imagePNG), let cg = rep.cgImage else { return .unavailable("obrázek nelze přečíst") }
        return ocr([cg])
    }

    public func screen(pdf: Data) -> ScreeningResult {
        guard let doc = PDFDocument(data: pdf) else { return .unavailable("PDF nelze přečíst") }
        if doc.isLocked { return .unavailable("PDF je zamčené") }
        guard doc.pageCount > 0, doc.pageCount <= Self.maxPDFPages else { return .unavailable("neočekávaný počet stránek") }

        var hits = Set<String>()
        hits.formUnion(SensitiveDataScanner.scan(doc.string ?? ""))
        if !hits.isEmpty { return .sensitive(hits.sorted()) }

        // Scanned pages have no text layer, so the first pages are also rendered and read by OCR.
        var images: [CGImage] = []
        for index in 0..<min(doc.pageCount, Self.ocrPDFPages) {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale = min(2.0, 2000 / max(bounds.width, bounds.height))
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumb = page.thumbnail(of: size, for: .mediaBox)
            if let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) { images.append(cg) }
        }
        switch ocr(images) {
        case .clear: return .clear("text-layer+ocr-scan")
        case let other: return other
        }
    }

    private func ocr(_ images: [CGImage]) -> ScreeningResult {
        var found = Set<String>()
        for image in images {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                return .unavailable("rozpoznání textu selhalo")
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            // Lines are scanned both separately and joined, because a label and its value are often on separate lines.
            found.formUnion(SensitiveDataScanner.scan(lines.joined(separator: "\n")))
            found.formUnion(SensitiveDataScanner.scan(lines.joined(separator: " ")))
        }
        return found.isEmpty ? .clear("ocr-scan") : .sensitive(found.sorted())
    }
}
