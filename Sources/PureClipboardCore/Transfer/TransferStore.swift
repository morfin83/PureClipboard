import Darwin
import Foundation

/// On-disk state of the file transfers: one JSON file per job, settings, and a drop folder for requests made by the helper.
/// Everything lives under `<support>/transfers` (0700) with 0600 files; nothing here is ever sent anywhere.
public struct TransferStore: Sendable {
    public let root: URL

    public init(supportDirectory: URL) {
        root = supportDirectory.appendingPathComponent("transfers", isDirectory: true)
    }

    private var jobsDirectory: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    public var queueDirectory: URL { root.appendingPathComponent("queue", isDirectory: true) }
    public var temporaryDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    private func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: Jobs

    public func save(_ job: TransferJob) throws {
        try ensure(jobsDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            try encoder.encode(job), to: jobsDirectory.appendingPathComponent("\(job.id).json"), mode: 0o600
        )
    }

    public func delete(_ id: String) {
        guard Self.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: jobsDirectory.appendingPathComponent("\(id).json"))
    }

    /// Loads all jobs; an unreadable file is set aside (`.corrupt`) instead of being deleted or crashing the app.
    public func loadJobs() -> [TransferJob] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path) else { return [] }
        var jobs: [TransferJob] = []
        for name in names where name.hasSuffix(".json") {
            let url = jobsDirectory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let job = try? JSONDecoder().decode(TransferJob.self, from: data),
               Self.isValidID(job.id), "\(job.id).json" == name {
                jobs.append(job)
            } else {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            }
        }
        return jobs.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    // MARK: Settings

    public func loadSettings() -> TransferSettings {
        guard let data = try? Data(contentsOf: settingsURL), var settings = try? JSONDecoder().decode(TransferSettings.self, from: data) else {
            return TransferSettings()
        }
        if let endpoint = settings.endpoint { settings.endpoint = TransferSettings.normalizedEndpoint(endpoint) }
        if !TransferSettings.isValidDestination(settings.destinationDirectory) {
            settings.destinationDirectory = TransferSettings.defaultDestination
        }
        return settings
    }

    public func save(_ settings: TransferSettings) throws {
        try ensure(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(settings), to: settingsURL, mode: 0o600)
    }

    // MARK: Request queue (helper → app)

    private struct Request: Codable {
        var paths: [String]
    }

    /// Called by the helper (`transfer-enqueue`): leaves a request file for the running app to pick up.
    @discardableResult
    public func enqueueRequest(paths: [String]) throws -> Int {
        let absolute = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        try ensure(root)
        try ensure(queueDirectory)
        let data = try JSONEncoder().encode(Request(paths: absolute))
        try AtomicFile.write(data, to: queueDirectory.appendingPathComponent("\(UUID().uuidString).json"), mode: 0o600)
        return absolute.count
    }

    /// Takes (and removes) all pending requests, oldest first.
    public func drainRequests() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: queueDirectory.path) else { return [] }
        var paths: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = queueDirectory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let request = try? JSONDecoder().decode(Request.self, from: data) {
                paths.append(contentsOf: request.paths)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return paths
    }

    // MARK: Temporary chunk files

    public func chunkURL(for id: String) throws -> URL {
        try ensure(temporaryDirectory)
        return temporaryDirectory.appendingPathComponent("\(id).chunk")
    }

    public func removeTemporaryFiles(for id: String) {
        try? FileManager.default.removeItem(at: temporaryDirectory.appendingPathComponent("\(id).chunk"))
    }
}

/// Reads a byte range of a file into a new file (the chunk handed to `adb push`).
enum ChunkWriter {
    static func write(from source: URL, offset: Int64, length: Int64, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(message: AtomicFile.errnoString()) }
        defer { close(fd) }
        try input.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let piece = Int(min(remaining, 1_048_576))
            guard let data = try input.read(upToCount: piece), !data.isEmpty else {
                throw TransferError.invalidSource("Zdrojový soubor je kratší, než se čekalo.")
            }
            var written = 0
            try data.withUnsafeBytes { buffer in
                while written < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + written, buffer.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw AtomicFile.Failure(message: AtomicFile.errnoString())
                    }
                    written += n
                }
            }
            remaining -= Int64(data.count)
        }
        _ = fsync(fd)
    }
}
