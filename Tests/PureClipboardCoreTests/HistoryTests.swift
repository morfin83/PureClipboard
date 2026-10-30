import AppKit
import Foundation
import PDFKit
import Testing
@testable import PureClipboardCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcr-history-\(UUID().uuidString)")
    return url
}

private func on(_ s: ClipboardHistorySettings = .defaults) -> ClipboardHistorySettings {
    var s = s
    s.enabled = true
    return s
}

private struct StubScreener: ContentScreener {
    var result: ScreeningResult
    func screen(imagePNG: Data) -> ScreeningResult { result }
    func screen(pdf: Data) -> ScreeningResult { result }
}

private func textItem(_ text: String, hash: String? = nil) -> NewHistoryItem {
    NewHistoryItem(
        kind: .text, preview: text, searchText: HistorySearch.fold(text), contentHash: hash ?? HistoryCapture.sha256(Data(text.utf8)),
        sourceApp: "Test", blobs: ["text": Data(text.utf8)], files: nil, screening: "text-scan"
    )
}

private func mode(_ url: URL) -> Int {
    var info = stat()
    lstat(url.path, &info)
    return Int(info.st_mode & 0o777)
}

private func png(width: Int = 40, height: Int = 20) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@Suite struct HistorySettingsTests {
    @Test func historyIsOffByDefaultWithDocumentedLimits() {
        let d = ClipboardHistorySettings.defaults
        #expect(!d.enabled && !d.paused && !d.isCapturing)
        #expect(d.maxItems == 100 && d.maxAgeDays == 30)
        #expect(!d.storeImages && !d.storePDF)
        #expect(d.validationIssues().isEmpty)
    }

    @Test func oldConfigWithoutHistoryKeyLoadsWithHistoryOffAndKeepsUnknownKeys() throws {
        let json = #"{"schemaVersion":1,"global":{"autoCopy":true,"historyLimit":100,"protectSensitiveData":true},"integrations":{"terminal":{"enabled":true,"mode":"diagnostics"},"claudeCode":{"enabled":true,"mode":"finalResponse"},"codex":{"enabled":true,"mode":"finalResponse"},"pureRemote":{"enabled":true,"mode":"actionResults"},"termux":{"enabled":true,"mode":"localClipboard"}},"future":1}"#
        var doc = try ConfigDocument(data: Data(json.utf8))
        #expect(doc.config.clipboardHistory == .defaults)
        doc.config.clipboardHistory.enabled = true
        let reloaded = try ConfigDocument(data: doc.encoded())
        #expect(reloaded.config.clipboardHistory.enabled)
        #expect(reloaded.config.global.historyLimit == 100)
        #expect(String(decoding: try doc.encoded(), as: UTF8.self).contains("\"future\""))
    }

    @Test func partialHistorySectionFallsBackPerField() throws {
        let s = try JSONDecoder().decode(ClipboardHistorySettings.self, from: Data(#"{"maxItems":7}"#.utf8))
        #expect(s.maxItems == 7 && !s.enabled && s.maxAgeDays == 30)
    }

    @Test func invalidValuesAreRejected() {
        var s = ClipboardHistorySettings.defaults
        s.maxItems = 0
        s.maxItemMegabytes = 500
        s.maxTotalMegabytes = 100
        #expect(s.validationIssues().count == 3)
        var c = PureClipboardConfig.defaults
        c.clipboardHistory.maxAgeDays = 9999
        #expect(!c.validationIssues().isEmpty)
    }
}

@Suite struct HistoryStoreTests {
    @Test func storesWithOwnerOnlyPermissionsAndReadsBack() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let item = try store.add(textItem("Ahoj světe"), settings: on())
        #expect(mode(dir) == 0o700 && mode(store.indexURL) == 0o600)
        let blob = store.blobDirectory.appendingPathComponent(item.blobs["text"]!)
        #expect(mode(blob) == 0o600)
        #expect(String(decoding: try store.data(for: item, role: "text"), as: UTF8.self) == "Ahoj světe")
        #expect(store.items().count == 1)
    }

    @Test func broaderDirectoryModeIsTightened() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try HistoryStore(directory: dir).add(textItem("a"), settings: on())
        #expect(mode(dir) == 0o700)
    }

    @Test func symlinkedDirectoryIsRefused() throws {
        let real = tempDir(), link = tempDir()
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: real); try? FileManager.default.removeItem(at: link) }
        #expect(throws: HistoryError.self) { try HistoryStore(directory: link).add(textItem("a"), settings: on()) }
    }

    @Test func identicalContentMovesToTopInsteadOfDuplicating() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = HistoryStore(directory: dir, now: { clock })
        _ = try store.add(textItem("one"), settings: on())
        clock += 10
        _ = try store.add(textItem("two"), settings: on())
        clock += 10
        _ = try store.add(textItem("one"), settings: on())
        let items = store.items()
        #expect(items.map(\.preview) == ["one", "two"])
    }

    @Test func countLimitDropsOldestAndRemovesTheirFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date()
        let store = HistoryStore(directory: dir, now: { clock })
        var s = on(); s.maxItems = 3
        for i in 0..<6 { clock += 1; _ = try store.add(textItem("item \(i)"), settings: s) }
        #expect(store.items().map(\.preview) == ["item 5", "item 4", "item 3"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.blobDirectory.path).count == 3)
    }

    @Test func ageLimitRemovesOldItems() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let store = HistoryStore(directory: dir, now: { clock })
        let s = on()
        _ = try store.add(textItem("old"), settings: s)
        clock += 31 * 86_400
        _ = try store.add(textItem("new"), settings: s)
        #expect(store.items().map(\.preview) == ["new"])
    }

    @Test func totalSizeLimitDropsOldestFirst() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date()
        let store = HistoryStore(directory: dir, now: { clock })
        var s = on(); s.maxItemMegabytes = 1; s.maxTotalMegabytes = 10
        for i in 0..<4 {
            clock += 1
            let big = String(repeating: Character(UnicodeScalar(65 + i)!), count: 4_000_000)
            _ = try store.add(textItem(big), settings: s)
        }
        #expect(store.items().count == 2)
        #expect(store.totalBytes() <= s.maxTotalBytes)
    }

    @Test func deleteOneAndClearAll() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let a = try store.add(textItem("a"), settings: on())
        _ = try store.add(textItem("b"), settings: on())
        try store.delete(id: a.id)
        #expect(store.items().map(\.preview) == ["b"])
        try Data("x".utf8).write(to: dir.appendingPathComponent("index.corrupt-1.json"))
        try store.clear()
        #expect(store.items().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.blobDirectory.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.corrupt-1.json").path))
    }

    @Test func corruptIndexIsSetAsideNotDeleted() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        _ = try store.add(textItem("a"), settings: on())
        try Data("{not json".utf8).write(to: store.indexURL)
        #expect(store.items().isEmpty)
        #expect(store.recoveryNotice != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("index.corrupt-") })
        // The store keeps working afterwards.
        _ = try store.add(textItem("b"), settings: on())
        #expect(store.items().map(\.preview) == ["b"])
    }

    @Test func missingPayloadDropsOnlyThatItem() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let a = try store.add(textItem("a"), settings: on())
        _ = try store.add(textItem("b"), settings: on())
        try FileManager.default.removeItem(at: store.blobDirectory.appendingPathComponent(a.blobs["text"]!))
        #expect(store.items().map(\.preview) == ["b"])
    }

    @Test func unsafeBlobNamesAreNeverFollowed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        var item = try store.add(textItem("a"), settings: on())
        item.blobs["text"] = "../../index.json"
        #expect(throws: HistoryError.self) { try store.data(for: item, role: "text") }
    }

    @Test func concurrentWritersDoNotLoseItems() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two store instances stand in for two processes: only the flock keeps them consistent.
        let a = HistoryStore(directory: dir), b = HistoryStore(directory: dir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try? (i.isMultiple(of: 2) ? a : b).add(textItem("c\(i)"), settings: on()) }
            }
        }
        #expect(HistoryStore(directory: dir).items().count == 20)
    }
}

@Suite struct HistoryCaptureTests {
    private func make(_ screener: ContentScreener = StubScreener(result: .clear("ocr-scan"))) -> (HistoryCapture, HistoryStore, URL) {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        return (HistoryCapture(store: store, screener: screener), store, dir)
    }

    @Test func offOrPausedStoresNothing() {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "hello")
        #expect(cap.process(snap, settings: .defaults) == .skipped("history-off"))
        var paused = on(); paused.paused = true
        #expect(cap.process(snap, settings: paused) == .skipped("history-off"))
        #expect(store.items().isEmpty)
    }

    @Test func plainTextIsStored() {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = cap.process(PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "Nákupní seznam\nmléko"), settings: on())
        guard case .stored = outcome else { Issue.record("not stored: \(outcome)"); return }
        #expect(store.items().first?.kind == .text)
        #expect(store.items().first?.preview == "Nákupní seznam mléko")
    }

    @Test func markedPrivateContentIsNeverStored() {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            let snap = PasteboardSnapshot(types: ["public.utf8-plain-text", marker], text: "harmless looking")
            #expect(cap.process(snap, settings: on()) == .skipped("marked-private"))
        }
        #expect(store.items().isEmpty)
    }

    @Test func sensitiveTextIsSkippedEvenWhenGlobalProtectionIsIrrelevant() {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "token: ghp_" + String(repeating: "a1B2", count: 8))
        #expect(cap.process(snap, settings: on()) == .skipped("sensitive-content"))
        #expect(store.items().isEmpty)
    }

    @Test func emptyAndOversizedTextAreSkipped() {
        let (cap, _, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cap.process(PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "  \n "), settings: on()) == .skipped("empty"))
        let big = String(repeating: "a ", count: 700_000)
        #expect(cap.process(PasteboardSnapshot(types: ["public.utf8-plain-text"], text: big), settings: on()) == .skipped("too-large"))
    }

    @Test func richTextKeepsFormattingAndPlainText() throws {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let attributed = NSAttributedString(string: "Tučný text", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let outcome = cap.process(PasteboardSnapshot(types: ["public.rtf"], rtf: rtf), settings: on())
        guard case .stored = outcome else { Issue.record("not stored"); return }
        let item = store.items()[0]
        #expect(item.kind == .richText && item.blobs.keys.sorted() == ["rtf", "text"])
    }

    @Test func filesAreStoredAsReferencesOnly() throws {
        let (cap, store, dir) = make()
        let folder = tempDir()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("zpráva.txt")
        try Data("tajný obsah souboru".utf8).write(to: file)
        let sub = folder.appendingPathComponent("Složka")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let outcome = cap.process(PasteboardSnapshot(types: ["public.file-url"], fileURLs: [file, sub]), settings: on())
        guard case .stored = outcome else { Issue.record("not stored"); return }
        let item = store.items()[0]
        #expect(item.kind == .files && item.blobs.isEmpty && item.byteSize == 0)
        #expect(item.files?.map(\.name) == ["zpráva.txt", "Složka"])
        #expect(item.files?.map(\.isDirectory) == [false, true])
        // No copy of the content exists anywhere in the history directory.
        let all = try FileManager.default.subpathsOfDirectory(atPath: dir.path).map { dir.appendingPathComponent($0) }
        for url in all where !url.hasDirectoryPath {
            #expect(!(String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)).contains("tajný obsah"))
        }
    }

    @Test func fileStatusReportsMissingAndMoved() throws {
        let folder = tempDir()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let ref = HistoryFileRef(path: file.path, name: "a.txt", isDirectory: false, bookmark: try file.bookmarkData())
        #expect(ref.resolve() == .available)
        let moved = folder.appendingPathComponent("b.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        guard case .moved(let found) = ref.resolve() else { Issue.record("expected moved"); return }
        #expect(URL(fileURLWithPath: found).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: moved)
        #expect(ref.resolve() == .missing)
    }

    @Test func imagesAndPDFsNeedSeparateConsent() {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = PasteboardSnapshot(types: ["public.png"], image: png())
        let pdf = PasteboardSnapshot(types: ["com.adobe.pdf"], pdf: Data("%PDF-1.4".utf8))
        #expect(cap.process(image, settings: on()) == .skipped("images-not-allowed"))
        #expect(cap.process(pdf, settings: on()) == .skipped("pdf-not-allowed"))
        var s = on(); s.storeImages = true
        if case .skipped = cap.process(image, settings: s) { Issue.record("image should be stored") }
        #expect(cap.process(pdf, settings: s) == .skipped("pdf-not-allowed"))
        s.storePDF = true
        if case .skipped = cap.process(pdf, settings: s) { Issue.record("pdf should be stored") }
        #expect(Set(store.items().map(\.kind)) == [.image, .pdf])
    }

    @Test func conservativeScreeningOutcomesBlockStorage() {
        var s = on(); s.storeImages = true; s.storePDF = true
        for (result, reason) in [(ScreeningResult.sensitive(["jwt"]), "sensitive-image"), (.unavailable("x"), "screening-unavailable")] {
            let (cap, store, dir) = make(StubScreener(result: result))
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(cap.process(PasteboardSnapshot(types: ["public.png"], image: png()), settings: s) == .skipped(reason))
            #expect(cap.process(PasteboardSnapshot(types: ["com.adobe.pdf"], pdf: Data("%PDF".utf8)), settings: s) == .skipped(reason))
            #expect(store.items().isEmpty)
        }
    }

    @Test func oversizedImageIsSkipped() {
        let (cap, _, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = on(); s.storeImages = true; s.maxItemMegabytes = 1
        let big = PasteboardSnapshot(types: ["public.png"], image: Data(count: 2_000_000))
        #expect(cap.process(big, settings: s) == .skipped("too-large"))
    }

    @Test func unknownFormatsAreSkipped() {
        let (cap, _, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cap.process(PasteboardSnapshot(types: ["com.example.private-format"]), settings: on()) == .skipped("unsupported-format"))
    }

    @Test func searchIgnoresCaseAndDiacritics() throws {
        let (cap, store, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = cap.process(PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "Žluťoučký kůň"), settings: on())
        _ = cap.process(PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "něco jiného"), settings: on())
        let items = store.items()
        #expect(HistorySearch.filter(items, query: "zlutoucky KUN").map(\.preview) == ["Žluťoučký kůň"])
        #expect(HistorySearch.filter(items, query: "").count == 2)
        #expect(HistorySearch.filter(items, query: "neexistuje").isEmpty)
    }
}

@Suite(.serialized) struct HistoryPasteboardTests {
    private func privateBoard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("pcr-test-\(UUID().uuidString)")) }

    private func monitorSetup(_ settings: ClipboardHistorySettings) -> (ClipboardHistoryMonitor, NSPasteboard, HistoryStore, HistorySettingsBox, URL) {
        let dir = tempDir()
        let board = privateBoard()
        let store = HistoryStore(directory: dir)
        let box = HistorySettingsBox(settings)
        let monitor = ClipboardHistoryMonitor(
            pasteboard: board, capture: HistoryCapture(store: store, screener: StubScreener(result: .clear("ocr-scan"))),
            settings: box, sourceApp: { "TestApp" })
        return (monitor, board, store, box, dir)
    }

    @Test func monitorCapturesOnlyCopiesMadeAfterItStarted() {
        let (monitor, board, store, _, dir) = monitorSetup(on())
        defer { try? FileManager.default.removeItem(at: dir) }
        board.clearContents(); board.setString("before start", forType: .string)
        monitor.start()
        defer { monitor.stop() }
        monitor.poll()
        #expect(store.items().isEmpty)
        board.clearContents(); board.setString("after start", forType: .string)
        monitor.poll()
        #expect(store.items().map(\.preview) == ["after start"])
        #expect(store.items().first?.sourceApp == "TestApp")
        #expect(monitor.currentStatus.storedCount == 1)
    }

    @Test func pausedMonitorRecordsNothingAndResumeDoesNotBackfill() {
        var s = on(); s.paused = true
        let (monitor, board, store, box, dir) = monitorSetup(s)
        defer { try? FileManager.default.removeItem(at: dir) }
        monitor.settingsChanged()
        #expect(!monitor.currentStatus.running)
        board.clearContents(); board.setString("while paused", forType: .string)
        monitor.poll()
        var resumed = s; resumed.paused = false
        box.current = resumed
        monitor.settingsChanged()
        defer { monitor.stop() }
        #expect(monitor.currentStatus.running)
        monitor.poll()
        #expect(store.items().isEmpty)
    }

    @Test func turningHistoryOffStopsTheMonitor() {
        let (monitor, _, _, box, dir) = monitorSetup(on())
        defer { try? FileManager.default.removeItem(at: dir) }
        monitor.settingsChanged()
        #expect(monitor.currentStatus.running)
        box.current = .defaults
        monitor.settingsChanged()
        #expect(!monitor.currentStatus.running)
    }

    @Test func skippedCopiesAreCountedWithoutContent() {
        let (monitor, board, store, _, dir) = monitorSetup(on())
        defer { try? FileManager.default.removeItem(at: dir) }
        monitor.start()
        defer { monitor.stop() }
        let item = NSPasteboardItem()
        item.setString("hunter2-password-manager-entry", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([item])
        monitor.poll()
        #expect(store.items().isEmpty)
        #expect(monitor.currentStatus.skippedCount == 1 && monitor.currentStatus.lastSkipReason == "marked-private")
    }

    @Test func fileCopyFromFinderSupportsMultipleSelection() throws {
        let (monitor, board, store, _, dir) = monitorSetup(on())
        let folder = tempDir()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        monitor.start()
        defer { monitor.stop() }
        board.clearContents(); board.writeObjects([a as NSURL, b as NSURL])
        monitor.poll()
        let item = try #require(store.items().first)
        #expect(item.kind == .files && item.files?.count == 2)
    }

    @Test func restoreRoundTripsTextRichTextImageAndFiles() throws {
        let dir = tempDir()
        let board = privateBoard()
        let store = HistoryStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = HistoryCapture(store: store, screener: StubScreener(result: .clear("ocr-scan")))
        var s = on(); s.storeImages = true

        _ = capture.process(PasteboardSnapshot(types: ["public.utf8-plain-text"], text: "obnov mě"), settings: s)
        var item = try #require(store.items().first)
        var outcome = PasteboardRestorer.restore(item, from: store, to: board)
        #expect(outcome.result == .restored && board.string(forType: .string) == "obnov mě")

        let attributed = NSAttributedString(string: "rich", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        _ = capture.process(PasteboardSnapshot(types: ["public.rtf"], rtf: rtf), settings: s)
        item = try #require(store.items().first { $0.kind == .richText })
        outcome = PasteboardRestorer.restore(item, from: store, to: board)
        #expect(outcome.result == .restored && board.data(forType: .rtf) == rtf && board.string(forType: .string) == "rich")

        let image = png()
        _ = capture.process(PasteboardSnapshot(types: ["public.png"], image: image), settings: s)
        item = try #require(store.items().first { $0.kind == .image })
        outcome = PasteboardRestorer.restore(item, from: store, to: board)
        #expect(outcome.result == .restored && board.data(forType: .png) == image)

        let folder = tempDir()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let f1 = folder.appendingPathComponent("1.txt"), f2 = folder.appendingPathComponent("2.txt")
        try Data("1".utf8).write(to: f1); try Data("2".utf8).write(to: f2)
        _ = capture.process(PasteboardSnapshot(types: ["public.file-url"], fileURLs: [f1, f2]), settings: s)
        item = try #require(store.items().first { $0.kind == .files })
        outcome = PasteboardRestorer.restore(item, from: store, to: board)
        #expect(outcome.result == .restored)
        #expect((board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 2)

        // One original gone: partial restore with a warning.
        try FileManager.default.removeItem(at: f2)
        outcome = PasteboardRestorer.restore(item, from: store, to: board)
        #expect(outcome.result == .partial(missing: 1))
        // All gone: the clipboard is left untouched.
        try FileManager.default.removeItem(at: f1)
        board.clearContents(); board.setString("zůstane", forType: .string)
        outcome = PasteboardRestorer.restore(item, from: store, to: board)
        if case .failed = outcome.result {} else { Issue.record("expected failure") }
        #expect(board.string(forType: .string) == "zůstane")
    }

    @Test func restoredItemIsNotCapturedAgain() throws {
        let (monitor, board, store, _, dir) = monitorSetup(on())
        defer { try? FileManager.default.removeItem(at: dir) }
        monitor.start()
        defer { monitor.stop() }
        board.clearContents(); board.setString("jednou", forType: .string)
        monitor.poll()
        let item = try #require(store.items().first)
        let outcome = PasteboardRestorer.restore(item, from: store, to: board)
        monitor.ignore(changeCount: outcome.changeCount)
        monitor.poll()
        #expect(store.items().count == 1 && monitor.currentStatus.storedCount == 1)
    }

    @Test func restoreTakesTheClipboardClaim() throws {
        let dir = tempDir(), claimsDir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: claimsDir) }
        let store = HistoryStore(directory: dir)
        let item = try store.add(textItem("x"), settings: on())
        let claims = ClipboardClaimStore(directory: claimsDir)
        _ = PasteboardRestorer.restore(item, from: store, to: privateBoard(), claims: claims)
        #expect(claims.withLock { claims.lastClaim()?.source } == "history")
    }
}

@Suite(.serialized) struct VisionScreeningTests {
    private func render(_ text: String) -> Data {
        let size = NSSize(width: 900, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func ocrFlagsASecretVisibleInAnImage() {
        let result = VisionContentScreener().screen(imagePNG: render("api_key = " + "Zx9Kq2Lm7Rt4Vb8N"))
        if case .sensitive = result {} else { Issue.record("OCR did not flag the image: \(result)") }
    }

    @Test func ocrLetsHarmlessImageThrough() {
        #expect(VisionContentScreener().screen(imagePNG: render("Hello PURE world")) == .clear("ocr-scan"))
    }

    @Test func pdfTextLayerIsScanned() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("password = Hunter2Hunter2!" as NSString).draw(at: NSPoint(x: 50, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        if case .sensitive = VisionContentScreener().screen(pdf: data as Data) {} else { Issue.record("PDF text layer not flagged") }
        #expect(VisionContentScreener().screen(pdf: Data("not a pdf".utf8)) == .unavailable("PDF nelze přečíst"))
    }
}
