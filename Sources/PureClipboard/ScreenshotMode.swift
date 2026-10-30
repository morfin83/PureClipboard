import AppKit
import PureClipboardCore
import SwiftUI

/// `PureClipboard --render-screenshots DIR` renders the real SwiftUI screens with invented sample data into PNG files
/// and exits. It never touches the user's configuration or clipboard: everything lives in a throw-away directory.
@MainActor
enum ScreenshotMode {
    static let flag = "--render-screenshots"
    static let unusedConfigURL = FileManager.default.temporaryDirectory.appendingPathComponent("pcr-no-config/config.json")

    static func outputDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pcr-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let configURL = scratch.appendingPathComponent("config.json")

        var config = PureClipboardConfig.defaults
        config.global.historyLimit = 100
        config.integrations.terminal.enabled = true
        config.integrations.claudeCode.enabled = true
        config.integrations.termux.enabled = true

        render(config: config, configURL: configURL, section: .clipboard, name: "app-clipboard", into: directory)
        render(config: config, configURL: configURL, section: .history, name: "app-history-off", into: directory)

        config.clipboardHistory.enabled = true
        config.clipboardHistory.storeImages = true
        seedHistory(directory: HistoryStore.defaultDirectory(configURL: configURL), settings: config.clipboardHistory, scratch: scratch)
        render(config: config, configURL: configURL, section: .history, name: "app-history-on", into: directory)
        render(config: config, configURL: configURL, section: .remote, name: "app-remote", into: directory)
    }

    private static func render(config: PureClipboardConfig, configURL: URL, section: StudioSection, name: String, into directory: URL) {
        let store = ConfigFileStore(url: configURL)
        try? store.save(ConfigDocument(config: config), expectedFingerprint: (try? store.load().fingerprint))
        let model = AppModel(store: store, monitoring: false)
        let view = ContentView(section: section, scrolling: false)
            .environment(model)
            .preferredColorScheme(.dark)
            .frame(width: 760)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
            print("\(name).png  \(rep.pixelsWide)×\(rep.pixelsHigh)")
        }
    }

    // MARK: Sample data (invented, harmless)

    private static func seedHistory(directory: URL, settings: ClipboardHistorySettings, scratch: URL) {
        var clock = Date().addingTimeInterval(-3 * 86_400)
        let store = HistoryStore(directory: directory, now: { clock })
        let capture = HistoryCapture(store: store, screener: VisionContentScreener())
        func copy(_ snapshot: PasteboardSnapshot, after seconds: TimeInterval) {
            clock.addTimeInterval(seconds)
            _ = capture.process(snapshot, settings: settings)
        }
        func text(_ value: String, app: String) -> PasteboardSnapshot {
            PasteboardSnapshot(types: ["public.utf8-plain-text"], text: value, sourceApp: app)
        }

        copy(text("Schůzka s Alenou v pátek v 10:00, zasedačka B", app: "Poznámky"), after: 60)
        let files = scratch.appendingPathComponent("Dokumenty")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let offer = files.appendingPathComponent("Nabídka-2026.pdf")
        let draft = files.appendingPathComponent("Koncept.txt")
        let gone = files.appendingPathComponent("Starý podklad.key")
        for url in [offer, draft, gone] { try? Data("ukázka".utf8).write(to: url) }
        copy(PasteboardSnapshot(types: ["public.file-url"], fileURLs: [offer, draft, gone], sourceApp: "Finder"), after: 7_200)
        try? FileManager.default.removeItem(at: gone)
        copy(PasteboardSnapshot(types: ["public.png"], image: samplePNG(), sourceApp: "Náhled"), after: 30_000)
        copy(text("swift test --filter HistoryTests", app: "Terminal"), after: 40_000)
        let rtf = try? NSAttributedString(string: "Pure Clipboard je klidný a soukromý nástroj.", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            .data(from: NSRange(location: 0, length: 44), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        copy(PasteboardSnapshot(types: ["public.rtf"], rtf: rtf, sourceApp: "Safari"), after: 90_000)
        copy(text("https://www.studiopuresound.cz/cs/lab/", app: "Safari"), after: 20_000)
        copy(text("Dobrý den, děkuji za zprávu. Odpovím do konce týdne.", app: "Mail"), after: 3_000)
    }

    private static func samplePNG() -> Data {
        let size = NSSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.42, green: 0.27, blue: 0.85, alpha: 1), NSColor(red: 0.13, green: 0.14, blue: 0.2, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 35)
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
