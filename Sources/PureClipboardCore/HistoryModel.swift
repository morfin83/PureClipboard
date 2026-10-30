import Foundation

/// User-controlled settings of the system clipboard history. Everything is off until the user turns it on.
public struct ClipboardHistorySettings: Codable, Equatable, Sendable {
    public static let maxItemsRange = 1...500
    public static let maxAgeDaysRange = 1...365
    public static let maxItemMegabytesRange = 1...50
    public static let maxTotalMegabytesRange = 10...2000

    public var enabled: Bool
    public var paused: Bool
    public var maxItems: Int
    public var maxAgeDays: Int
    public var maxItemMegabytes: Int
    public var maxTotalMegabytes: Int
    /// Separate consent: images are only screened by on-device OCR, which cannot find every secret.
    public var storeImages: Bool
    /// Separate consent, see `storeImages`.
    public var storePDF: Bool

    public static let defaults = ClipboardHistorySettings(
        enabled: false, paused: false, maxItems: 100, maxAgeDays: 30,
        maxItemMegabytes: 10, maxTotalMegabytes: 200, storeImages: false, storePDF: false
    )

    public init(
        enabled: Bool, paused: Bool, maxItems: Int, maxAgeDays: Int,
        maxItemMegabytes: Int, maxTotalMegabytes: Int, storeImages: Bool, storePDF: Bool
    ) {
        self.enabled = enabled
        self.paused = paused
        self.maxItems = maxItems
        self.maxAgeDays = maxAgeDays
        self.maxItemMegabytes = maxItemMegabytes
        self.maxTotalMegabytes = maxTotalMegabytes
        self.storeImages = storeImages
        self.storePDF = storePDF
    }

    /// Missing keys fall back to the defaults, so a partial or older file never turns history on.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
        maxAgeDays = try c.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? d.maxAgeDays
        maxItemMegabytes = try c.decodeIfPresent(Int.self, forKey: .maxItemMegabytes) ?? d.maxItemMegabytes
        maxTotalMegabytes = try c.decodeIfPresent(Int.self, forKey: .maxTotalMegabytes) ?? d.maxTotalMegabytes
        storeImages = try c.decodeIfPresent(Bool.self, forKey: .storeImages) ?? d.storeImages
        storePDF = try c.decodeIfPresent(Bool.self, forKey: .storePDF) ?? d.storePDF
    }

    public func validationIssues() -> [String] {
        var issues: [String] = []
        func check(_ value: Int, _ range: ClosedRange<Int>, _ name: String) {
            if !range.contains(value) {
                issues.append("clipboardHistory.\(name) musí být v rozsahu \(range.lowerBound)–\(range.upperBound), nalezeno \(value).")
            }
        }
        check(maxItems, Self.maxItemsRange, "maxItems")
        check(maxAgeDays, Self.maxAgeDaysRange, "maxAgeDays")
        check(maxItemMegabytes, Self.maxItemMegabytesRange, "maxItemMegabytes")
        check(maxTotalMegabytes, Self.maxTotalMegabytesRange, "maxTotalMegabytes")
        if maxItemMegabytes > maxTotalMegabytes {
            issues.append("clipboardHistory.maxItemMegabytes nesmí být větší než maxTotalMegabytes.")
        }
        return issues
    }

    public var maxItemBytes: Int { maxItemMegabytes * 1_048_576 }
    public var maxTotalBytes: Int { maxTotalMegabytes * 1_048_576 }
    /// True when the monitor should be reading the pasteboard.
    public var isCapturing: Bool { enabled && !paused }
}

public enum HistoryKind: String, Codable, Sendable, CaseIterable {
    case text, richText, image, pdf, files

    public var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Formátovaný text"
        case .image: "Obrázek"
        case .pdf: "PDF"
        case .files: "Soubory"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .files: "folder"
        }
    }
}

/// A reference to an original file or folder. The content of the file is never copied.
public struct HistoryFileRef: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// Lets us find the original again if it was moved or renamed.
    public var bookmark: Data?

    public init(path: String, name: String, isDirectory: Bool, bookmark: Data?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.bookmark = bookmark
    }

    public enum Status: Equatable, Sendable {
        case available
        case moved(to: String)
        case missing

        public var label: String {
            switch self {
            case .available: "Originál je k dispozici"
            case .moved(let path): "Originál byl přesunut: \(path)"
            case .missing: "Originál už neexistuje"
            }
        }
    }

    /// Where the original is now, if it can still be found.
    public func resolve() -> Status {
        if FileManager.default.fileExists(atPath: path) { return .available }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return .moved(to: url.path)
            }
        }
        return .missing
    }
}

public struct HistoryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: HistoryKind
    /// Short text shown in the list (for images and PDFs a description, never content).
    public var preview: String
    /// Lower-cased text used by the search (empty for items without text).
    public var searchText: String
    public var byteSize: Int
    public var contentHash: String
    public var sourceApp: String?
    /// role ("text", "rtf", "image", "pdf") → file name inside the blob directory.
    public var blobs: [String: String]
    public var files: [HistoryFileRef]?
    /// What was checked before storing, e.g. "text-scan", "ocr-scan".
    public var screening: String

    public init(
        id: UUID = UUID(), createdAt: Date, kind: HistoryKind, preview: String, searchText: String,
        byteSize: Int, contentHash: String, sourceApp: String?, blobs: [String: String],
        files: [HistoryFileRef]?, screening: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.preview = preview
        self.searchText = searchText
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.sourceApp = sourceApp
        self.blobs = blobs
        self.files = files
        self.screening = screening
    }
}

/// An item that passed all checks and is about to be stored.
public struct NewHistoryItem: Sendable {
    public var kind: HistoryKind
    public var preview: String
    public var searchText: String
    public var contentHash: String
    public var sourceApp: String?
    public var blobs: [String: Data]
    public var files: [HistoryFileRef]?
    public var screening: String

    public init(
        kind: HistoryKind, preview: String, searchText: String, contentHash: String, sourceApp: String?,
        blobs: [String: Data], files: [HistoryFileRef]?, screening: String
    ) {
        self.kind = kind
        self.preview = preview
        self.searchText = searchText
        self.contentHash = contentHash
        self.sourceApp = sourceApp
        self.blobs = blobs
        self.files = files
        self.screening = screening
    }

    public var byteSize: Int { blobs.values.reduce(0) { $0 + $1.count } }
}

public enum HistorySearch {
    /// Case- and diacritics-insensitive match against preview, text, source app and file names.
    public static func filter(_ items: [HistoryItem], query: String) -> [HistoryItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            var haystack = fold(item.preview) + " " + item.searchText + " " + fold(item.kind.label)
            if let app = item.sourceApp { haystack += " " + fold(app) }
            for file in item.files ?? [] { haystack += " " + fold(file.name) }
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    public static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
