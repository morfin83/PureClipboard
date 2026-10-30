import Darwin
import Foundation

public enum HistoryError: Error, Equatable, LocalizedError, Sendable {
    case directoryUnsafe(String)
    case lockUnavailable
    case writeFailed(String)
    case blobMissing

    public var errorDescription: String? {
        switch self {
        case .directoryUnsafe(let reason): "Složka historie není bezpečná: \(reason)."
        case .lockUnavailable: "Historii právě používá jiný proces. Zkuste to znovu."
        case .writeFailed(let reason): "Uložení historie selhalo: \(reason)."
        case .blobMissing: "Data položky chybí."
        }
    }
}

/// On-disk clipboard history: `index.json` plus one file per payload in `blobs/`.
/// Everything is mode 0600 inside a 0700 directory. Writes are atomic and guarded by an in-process lock and a `flock`,
/// so two app instances cannot corrupt each other. Content never leaves the Mac.
public final class HistoryStore: @unchecked Sendable {
    struct Index: Codable {
        var version = 1
        var items: [HistoryItem] = []
    }

    public let directory: URL
    private let now: () -> Date
    private let mutex = NSLock()

    /// Set when the index could not be read and was set aside; cleared by `clearRecoveryNotice()`.
    public private(set) var recoveryNotice: String?

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    public static func defaultDirectory(configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("history", isDirectory: true)
    }

    var indexURL: URL { directory.appendingPathComponent("index.json") }
    var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    var lockURL: URL { directory.appendingPathComponent(".history.lock") }

    // MARK: Reading

    public func items() -> [HistoryItem] {
        (try? locked { index in index.items.sorted { $0.createdAt > $1.createdAt } }) ?? []
    }

    public func totalBytes() -> Int {
        items().reduce(0) { $0 + $1.byteSize }
    }

    public func data(for item: HistoryItem, role: String) throws -> Data {
        guard let name = item.blobs[role], Self.isSafeBlobName(name) else { throw HistoryError.blobMissing }
        let url = blobDirectory.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: url) else { throw HistoryError.blobMissing }
        return data
    }

    public func clearRecoveryNotice() {
        mutex.lock()
        recoveryNotice = nil
        mutex.unlock()
    }

    // MARK: Writing

    /// Stores `new` (or moves an identical item to the top), then applies the retention limits.
    @discardableResult
    public func add(_ new: NewHistoryItem, settings: ClipboardHistorySettings) throws -> HistoryItem {
        try locked(writing: true) { index in
            let stamp = now()
            if let i = index.items.firstIndex(where: { $0.contentHash == new.contentHash && $0.kind == new.kind }) {
                index.items[i].createdAt = stamp
                index.items[i].sourceApp = new.sourceApp ?? index.items[i].sourceApp
                return index.items[i]
            }
            var names: [String: String] = [:]
            do {
                try ensureDirectories()
                for (role, data) in new.blobs {
                    let name = UUID().uuidString.lowercased() + ".bin"
                    try AtomicFile.write(data, to: blobDirectory.appendingPathComponent(name), mode: 0o600, createDirectory: false)
                    names[role] = name
                }
            } catch {
                for name in names.values { unlink(blobDirectory.appendingPathComponent(name).path) }
                throw HistoryError.writeFailed(error.localizedDescription)
            }
            let item = HistoryItem(
                createdAt: stamp, kind: new.kind, preview: new.preview, searchText: new.searchText,
                byteSize: new.byteSize, contentHash: new.contentHash, sourceApp: new.sourceApp,
                blobs: names, files: new.files, screening: new.screening
            )
            index.items.append(item)
            return item
        } finalize: { index in
            Self.prune(&index, settings: settings, now: self.now())
        }
    }

    public func delete(id: UUID) throws {
        try locked(writing: true) { index in
            index.items.removeAll { $0.id == id }
        }
    }

    /// Removes every item, every payload and any index files set aside after corruption.
    public func clear() throws {
        try locked(writing: true) { index in
            index.items.removeAll()
        } finalize: { _ in
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix("index.corrupt-") {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Applies the age, count and size limits (also called on start).
    public func prune(settings: ClipboardHistorySettings) throws {
        try locked(writing: true) { _ in } finalize: { index in
            Self.prune(&index, settings: settings, now: self.now())
        }
    }

    static func prune(_ index: inout Index, settings: ClipboardHistorySettings, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(settings.maxAgeDays) * 86_400)
        index.items.removeAll { $0.createdAt < cutoff }
        index.items.sort { $0.createdAt > $1.createdAt }
        if index.items.count > settings.maxItems { index.items.removeLast(index.items.count - settings.maxItems) }
        var total = index.items.reduce(0) { $0 + $1.byteSize }
        while total > settings.maxTotalBytes, let last = index.items.popLast() { total -= last.byteSize }
    }

    // MARK: Internals

    static func isSafeBlobName(_ name: String) -> Bool {
        name.count <= 64 && name.hasSuffix(".bin")
            && name.dropLast(4).unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
    }

    private func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [directory, blobDirectory] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw HistoryError.directoryUnsafe("\(url.lastPathComponent) není složka nebo je to symbolický odkaz")
                }
                if info.st_uid != getuid() { throw HistoryError.directoryUnsafe("patří jinému uživateli") }
                if info.st_mode & 0o077 != 0 { chmod(url.path, 0o700) }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
    }

    /// Runs `body` on the loaded index under both locks. A write happens only when `writing` is true.
    /// `finalize` runs after `body` (retention, cleanup); orphaned payload files are removed after every write.
    private func locked<T>(
        writing: Bool = false,
        _ body: (inout Index) throws -> T,
        finalize: ((inout Index) -> Void)? = nil
    ) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }

        var info = stat()
        let exists = lstat(directory.path, &info) == 0
        if !exists && !writing { var empty = Index(); return try body(&empty) }
        try ensureDirectories()

        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HistoryError.lockUnavailable }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw HistoryError.lockUnavailable }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }

        var index = loadIndex()
        let result = try body(&index)
        guard writing else { return result }
        finalize?(&index)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try AtomicFile.write(try encoder.encode(index), to: indexURL, mode: 0o600, createDirectory: false)
        } catch {
            throw HistoryError.writeFailed(error.localizedDescription)
        }
        removeOrphans(keeping: index)
        return result
    }

    /// A broken index is moved aside (never silently deleted) and history starts empty.
    private func loadIndex() -> Index {
        var info = stat()
        guard lstat(indexURL.path, &info) == 0 else { return Index() }
        guard (info.st_mode & S_IFMT) == S_IFREG, let data = try? Data(contentsOf: indexURL) else {
            setAside("soubor nelze přečíst")
            return Index()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var index = try? decoder.decode(Index.self, from: data), index.version == 1 else {
            setAside("soubor je poškozený nebo má neznámou verzi")
            return Index()
        }
        // Drop entries whose payload vanished; they could never be restored.
        index.items.removeAll { item in
            item.kind != .files && item.blobs.isEmpty
                || item.blobs.values.contains { !FileManager.default.fileExists(atPath: blobDirectory.appendingPathComponent($0).path) }
        }
        return index
    }

    private func setAside(_ reason: String) {
        let target = directory.appendingPathComponent("index.corrupt-\(Int(now().timeIntervalSince1970)).json")
        if rename(indexURL.path, target.path) != 0 { unlink(indexURL.path) }
        chmod(target.path, 0o600)
        recoveryNotice = "Soubor historie byl poškozený (\(reason)); byl odložen jako \(target.lastPathComponent) a historie začíná prázdná."
    }

    private func removeOrphans(keeping index: Index) {
        let keep = Set(index.items.flatMap { $0.blobs.values })
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }
}
