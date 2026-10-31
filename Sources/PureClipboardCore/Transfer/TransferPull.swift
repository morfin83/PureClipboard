import Darwin
import Foundation

/// What a pull may read from the phone. Only plain file names directly inside the phone's Downloads folder qualify.
public enum PullSafety {
    public static let downloadsFolder = "/sdcard/Download"

    /// A plain file name: no `/`, no `..`, no control characters, not hidden (the `.pureclipboard` staging folder is hidden).
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 240, !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    /// `/sdcard/Download/<safe name>` and nothing else: no subfolders, no other folders of the phone.
    public static func isAllowedSource(_ path: String) -> Bool {
        let prefix = downloadsFolder + "/"
        guard path.hasPrefix(prefix) else { return false }
        return isSafeName(String(path.dropFirst(prefix.count)))
    }
}

/// Phone → Mac, the mirror of `TransferEngine`. The phone's file is checked (size, time), hashed on the phone, then read in
/// ranges into `<store>/pull/<id>.part` on this Mac. The size of that partial file decides where to continue. After the last
/// range the local SHA-256 must match the phone's; only then is the file linked into the destination, which never overwrites.
public actor PullEngine {
    public typealias Observer = @Sendable ([TransferJob], [String: Double]) -> Void

    private let store: TransferStore
    private let resolver: any PhoneResolving
    private var settings: TransferSettings
    private let destination: @Sendable () -> URL
    private let wallClock: @Sendable () -> TimeInterval
    private let monotonic: @Sendable () -> TimeInterval
    private let retryDelay: TimeInterval
    private let chunkSizeFor: @Sendable (TransferLink) -> Int64
    private let reserveBytes: Int64 = 64 * 1_048_576

    private var jobs: [String: TransferJob] = [:]
    private var meters: [String: TransferSpeedMeter] = [:]
    private var sessionStart: [String: (time: TimeInterval, bytes: Int64)] = [:]
    private var pauseRequested: Set<String> = []
    private var cancelRequested: Set<String> = []
    private var worker: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runningID: String?
    private var observer: Observer?

    public init(
        store: TransferStore, resolver: any PhoneResolving, settings: TransferSettings = TransferSettings(),
        destination: @escaping @Sendable () -> URL = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] },
        retryDelay: TimeInterval = 1,
        chunkSizeFor: @escaping @Sendable (TransferLink) -> Int64 = { $0.chunkSize },
        wallClock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.resolver = resolver
        self.settings = settings
        self.destination = destination
        self.retryDelay = retryDelay
        self.chunkSizeFor = chunkSizeFor
        self.wallClock = wallClock
        self.monotonic = monotonic
        for var job in store.loadJobs() where job.direction == .pull {
            // Like pushes: a job active at shutdown is never resumed on its own.
            if !job.state.isFinished && job.state != .paused {
                job.state = .paused
                job.pauseReason = .interrupted
                job.message = "Stahování bylo přerušeno ukončením aplikace. Pokračuje od posledního uloženého místa."
                try? store.save(job)
            }
            jobs[job.id] = job
        }
    }

    // MARK: Observation

    public func setObserver(_ observer: @escaping Observer) {
        self.observer = observer
        publish()
    }

    public func currentJobs() -> [TransferJob] {
        jobs.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func updateSettings(_ new: TransferSettings) {
        settings = new
    }

    private func publish() {
        var speeds: [String: Double] = [:]
        for (id, job) in jobs where job.state == .running || job.state == .pausing {
            speeds[id] = meters[id]?.bytesPerSecond ?? 0
        }
        observer?(currentJobs(), speeds)
    }

    private func mutate(_ id: String, _ change: (inout TransferJob) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
        try? store.save(job)
        publish()
    }

    // MARK: Commands

    /// Lists the phone's Downloads folder. Throws when there is no phone, so the UI can say why.
    public func listDownloads() async throws -> [PhoneFileEntry] {
        let target = try await resolver.resolve(settings: settings)
        return try await target.phone.listFiles(in: PullSafety.downloadsFolder)
    }

    /// Queues files picked from the list. Paths outside the allowed folder are rejected by name.
    @discardableResult
    public func enqueue(_ files: [PhoneFileEntry]) -> TransferEnqueueResult {
        var result = TransferEnqueueResult(added: 0, rejected: [])
        let folder = destination().path
        for file in files {
            guard PullSafety.isAllowedSource(file.path), file.size >= 0 else {
                result.rejected.append(file.name)
                continue
            }
            if jobs.values.contains(where: { $0.sourcePath == file.path && $0.modifiedAt == file.modifiedAt && !$0.state.isFinished }) {
                continue
            }
            let job = TransferJob(
                sourcePath: file.path, sourceName: file.name, size: file.size, modifiedAt: file.modifiedAt,
                destinationDirectory: folder, direction: .pull, createdAt: wallClock()
            )
            jobs[job.id] = job
            try? store.save(job)
            result.added += 1
        }
        publish()
        if result.added > 0 { kick() }
        return result
    }

    public func pause(_ id: String) {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .queued:
            mutate(id) { $0.state = .paused; $0.pauseReason = .user; $0.message = nil }
        case .preparing, .running:
            pauseRequested.insert(id)
            mutate(id) { $0.state = .pausing }
        default:
            break
        }
    }

    public func resume(_ id: String, allowMobileData: Bool = false) {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .pausing:
            pauseRequested.remove(id)
            mutate(id) { $0.state = .running }
        case .paused, .failed:
            pauseRequested.remove(id)
            mutate(id) {
                $0.state = .queued
                $0.pauseReason = nil
                $0.message = nil
                if allowMobileData { $0.allowMobileData = true }
            }
            kick()
        default:
            break
        }
    }

    public func cancel(_ id: String) async {
        guard jobs[id].map({ !$0.state.isFinished }) == true else { return }
        if runningID == id {
            cancelRequested.insert(id)
            runTask?.cancel()
            return
        }
        mutate(id) { $0.state = .canceled; $0.pauseReason = nil; $0.message = "Zrušeno." }
        store.removePartialFile(for: id)
    }

    public func remove(_ id: String) async {
        guard let job = jobs[id] else { return }
        if !job.state.isFinished { await cancel(id) }
        if runningID == id { return }
        jobs[id] = nil
        meters[id] = nil
        store.delete(id)
        store.removePartialFile(for: id)
        publish()
    }

    public func clearFinished() {
        for (id, job) in jobs where job.state.isFinished && runningID != id {
            jobs[id] = nil
            store.delete(id)
        }
        publish()
    }

    public func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    // MARK: Worker

    private func kick() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    private func nextQueued() -> String? {
        currentJobs().first { $0.state == .queued }?.id
    }

    private func drain() async {
        while let id = nextQueued() {
            runningID = id
            let task = Task { await self.run(id) }
            runTask = task
            await task.value
            runTask = nil
            runningID = nil
        }
        worker = nil
    }

    private func run(_ id: String) async {
        do {
            try await perform(id)
        } catch is CancellationError {
            if cancelRequested.remove(id) != nil {
                mutate(id) { $0.state = .canceled; $0.pauseReason = nil; $0.message = "Zrušeno." }
                store.removePartialFile(for: id)
            } else {
                mutate(id) { $0.state = .paused; $0.pauseReason = .interrupted; $0.message = "Stahování bylo přerušeno." }
            }
        } catch let error as TransferError {
            switch error {
            case .noPhone(let detail):
                pauseJob(id, reason: .noPhone, message: detail)
            case .commandFailed, .timedOut, .sizeMismatch:
                pauseJob(id, reason: .connectionLost, message: (error.errorDescription ?? "") + " Pokračujte tlačítkem Pokračovat.")
            default:
                failJob(id, message: error.errorDescription ?? "Stahování selhalo.")
            }
        } catch {
            failJob(id, message: error.localizedDescription)
        }
        pauseRequested.remove(id)
        cancelRequested.remove(id)
        meters[id] = nil
        sessionStart[id] = nil
        publish()
    }

    private func pauseJob(_ id: String, reason: TransferPauseReason, message: String?) {
        mutate(id) { $0.state = .paused; $0.pauseReason = reason; $0.message = message }
    }

    private func failJob(_ id: String, message: String) {
        mutate(id) { $0.state = .failed; $0.pauseReason = nil; $0.message = message; $0.finishedAt = wallClock() }
    }

    // MARK: One download

    private func perform(_ id: String) async throws {
        guard var job = jobs[id] else { return }
        mutate(id) {
            $0.state = .preparing
            $0.pauseReason = nil
            $0.message = nil
            if $0.startedAt == nil { $0.startedAt = wallClock() }
        }
        guard PullSafety.isAllowedSource(job.sourcePath) else {
            throw TransferError.invalidSource("Zdroj je mimo povolenou složku Stažené.")
        }

        let target = try await resolver.resolve(settings: settings)
        let phone = target.phone
        mutate(id) { $0.link = target.link }
        job = jobs[id] ?? job

        if target.link == .mobile && !job.allowMobileData {
            return pauseJob(
                id, reason: .mobileData,
                message: "Telefon je dostupný jen přes mobilní data. Stahování by je čerpalo; potvrďte tlačítkem „Přesto stáhnout“, nebo zapněte Wi‑Fi."
            )
        }

        // The phone's file must still be the one that was listed.
        guard let remote = try await phone.entry(at: job.sourcePath) else {
            throw TransferError.invalidSource("Soubor na telefonu už neexistuje.")
        }
        guard remote.size == job.size, remote.modifiedAt == job.modifiedAt else {
            throw TransferError.invalidSource("Soubor na telefonu se od zařazení změnil. Vyberte ho znovu v seznamu.")
        }
        if job.sha256 == nil {
            let digest = try await phone.sha256(of: job.sourcePath)
            mutate(id) { $0.sha256 = digest }
            job = jobs[id] ?? job
        }
        guard let expected = job.sha256 else { throw TransferError.commandFailed("sha256sum nevrátil součet") }
        if pauseRequested.contains(id) { return pauseJob(id, reason: .user, message: nil) }

        let directory = job.destinationDirectory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if job.destinationName == nil {
            let base = TransferNaming.sanitized(job.sourceName)
            var chosen: String?
            for attempt in 1...99 {
                let candidate = TransferNaming.candidate(base, attempt: attempt)
                if !FileManager.default.fileExists(atPath: "\(directory)/\(candidate)") { chosen = candidate; break }
            }
            guard let chosen else { throw TransferError.destinationBusy }
            mutate(id) { $0.destinationName = chosen }
        }

        let partURL = try store.partialURL(for: id)
        var delivered = Self.fileSize(partURL)
        if delivered > job.size {
            try? FileManager.default.removeItem(at: partURL)
            delivered = 0
        }
        let available = Self.availableBytes(in: directory)
        let needed = job.size - delivered + reserveBytes
        if let available, available < needed { throw TransferError.notEnoughSpace(needed: needed, available: available) }

        mutate(id) { $0.bytesDone = delivered; $0.state = .running }
        var meter = TransferSpeedMeter()
        meter.reset(at: monotonic(), bytes: delivered)
        meters[id] = meter
        sessionStart[id] = (monotonic(), delivered)
        publish()

        let file = try PartFile(url: partURL)
        let chunkSize = chunkSizeFor(target.link)
        while delivered < job.size {
            try Task.checkCancellation()
            if pauseRequested.contains(id) { return pauseJob(id, reason: .user, message: nil) }
            let length = min(chunkSize, job.size - delivered)
            let data = try await fetch(job.sourcePath, offset: delivered, length: length, phone: phone)
            try file.write(data, at: delivered)
            delivered += length
            meters[id]?.add(bytes: delivered, at: monotonic())
            mutate(id) { $0.bytesDone = delivered }
        }

        mutate(id) { $0.state = .verifying }
        let localPath = partURL.path
        let local = try await Task.detached(priority: .utility) { try TransferEngine.sha256(ofFileAt: localPath) }.value
        try Task.checkCancellation()
        guard local == expected else {
            store.removePartialFile(for: id)
            mutate(id) { $0.bytesDone = 0 }
            throw TransferError.checksumMismatch
        }

        let finalName = try Self.placeWithoutOverwriting(partURL, in: directory, name: job.sourceName)
        store.removePartialFile(for: id)

        let end = monotonic()
        let average = sessionStart[id].flatMap { start -> Double? in
            end > start.time ? Double(job.size - start.bytes) / (end - start.time) : nil
        }
        mutate(id) {
            $0.destinationName = finalName
            $0.bytesDone = $0.size
            $0.state = .completed
            $0.message = nil
            $0.finishedAt = wallClock()
            $0.averageBytesPerSecond = average
        }
    }

    /// Reads one range; a failed or lost reply is simply asked again, because reads have no side effects.
    private func fetch(_ path: String, offset: Int64, length: Int64, phone: any PhoneFiles) async throws -> Data {
        var lastError: Error = TransferError.timedOut
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let data = try await phone.readRange(path, offset: offset, length: length)
                guard Int64(data.count) == length else {
                    throw TransferError.sizeMismatch(expected: length, actual: Int64(data.count))
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            if attempt < 2 { try await Task.sleep(for: .seconds(retryDelay * Double(attempt + 1))) }
        }
        throw lastError
    }

    // MARK: Local files

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func availableBytes(in directory: String) -> Int64? {
        let values = try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Hard-links the finished file under the first free name, then removes the partial file. `link(2)` never replaces
    /// an existing file, so a download cannot overwrite anything, not even one created a moment earlier.
    static func placeWithoutOverwriting(_ source: URL, in directory: String, name: String) throws -> String {
        let base = TransferNaming.sanitized(name)
        for attempt in 1...99 {
            let candidate = TransferNaming.candidate(base, attempt: attempt)
            if link(source.path, "\(directory)/\(candidate)") == 0 {
                unlink(source.path)
                return candidate
            }
            guard errno == EEXIST else { throw AtomicFile.Failure(message: AtomicFile.errnoString()) }
        }
        throw TransferError.destinationBusy
    }
}

/// The partial file on this Mac. Writes go to an explicit offset, so repeating a range never duplicates bytes.
private final class PartFile {
    private let fd: Int32

    init(url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(message: AtomicFile.errnoString()) }
    }

    deinit { close(fd) }

    func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = pwrite(fd, buffer.baseAddress! + written, buffer.count - written, off_t(offset) + off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFile.Failure(message: AtomicFile.errnoString())
                }
                written += n
            }
        }
        guard fsync(fd) == 0 else { throw AtomicFile.Failure(message: AtomicFile.errnoString()) }
    }
}
