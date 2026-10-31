import CryptoKit
import Darwin
import Foundation

public struct TransferEnqueueResult: Sendable, Equatable {
    public var added: Int
    public var rejected: [String]
}

/// Sends files to the phone in chunks that are appended to one partial file there.
/// The size of that partial file is the single source of truth for "how much has arrived", so pausing, an app restart
/// and a dropped connection all continue from the last delivered byte instead of starting over.
public actor TransferEngine {
    public typealias Observer = @Sendable ([TransferJob], [String: Double]) -> Void

    private let store: TransferStore
    private let resolver: any PhoneResolving
    private var settings: TransferSettings
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
        retryDelay: TimeInterval = 1,
        chunkSizeFor: @escaping @Sendable (TransferLink) -> Int64 = { $0.chunkSize },
        wallClock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.resolver = resolver
        self.settings = settings
        self.retryDelay = retryDelay
        self.chunkSizeFor = chunkSizeFor
        self.wallClock = wallClock
        self.monotonic = monotonic
        // Pulls have their own engine (`PullEngine`) and read the same store; only push jobs belong here.
        for var job in store.loadJobs() where job.direction == .push {
            // A job that was active when the app stopped is never resumed on its own: the link may be mobile data now.
            if !job.state.isFinished && job.state != .paused {
                job.state = .paused
                job.pauseReason = .interrupted
                job.message = "Přenos byl přerušen ukončením aplikace. Pokračuje od posledního doručeného místa."
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

    private func mutate(_ id: String, publish shouldPublish: Bool = true, _ change: (inout TransferJob) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
        try? store.save(job)
        if shouldPublish { publish() }
    }

    // MARK: Commands

    @discardableResult
    public func enqueue(paths: [String]) -> TransferEnqueueResult {
        var result = TransferEnqueueResult(added: 0, rejected: [])
        for raw in paths {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                result.rejected.append(path)
                continue
            }
            let modified = Double(info.st_mtimespec.tv_sec)
            if jobs.values.contains(where: { $0.sourcePath == path && $0.modifiedAt == modified && !$0.state.isFinished }) {
                continue
            }
            let job = TransferJob(
                sourcePath: path, sourceName: URL(fileURLWithPath: path).lastPathComponent,
                size: Int64(info.st_size), modifiedAt: modified,
                destinationDirectory: settings.destinationDirectory, createdAt: wallClock()
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
        guard let job = jobs[id], !job.state.isFinished else { return }
        if runningID == id {
            cancelRequested.insert(id)
            runTask?.cancel()
            return
        }
        mutate(id) { $0.state = .canceled; $0.pauseReason = nil; $0.message = "Zrušeno." }
        await cleanupPhone(for: job)
        store.removeTemporaryFiles(for: id)
    }

    public func remove(_ id: String) async {
        guard let job = jobs[id] else { return }
        if !job.state.isFinished { await cancel(id) }
        if runningID == id { return }
        jobs[id] = nil
        meters[id] = nil
        store.delete(id)
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
            if cancelRequested.remove(id) != nil, let job = jobs[id] {
                await cleanupPhone(for: job)
                mutate(id) { $0.state = .canceled; $0.pauseReason = nil; $0.message = "Zrušeno." }
            } else {
                mutate(id) { $0.state = .paused; $0.pauseReason = .interrupted; $0.message = "Přenos byl přerušen." }
            }
        } catch let error as TransferError {
            switch error {
            case .noPhone(let detail):
                pauseJob(id, reason: .noPhone, message: detail)
            case .commandFailed, .timedOut, .sizeMismatch:
                pauseJob(id, reason: .connectionLost, message: (error.errorDescription ?? "") + " Pokračujte tlačítkem Pokračovat.")
            default:
                failJob(id, message: error.errorDescription ?? "Přenos selhal.")
            }
        } catch {
            failJob(id, message: error.localizedDescription)
        }
        store.removeTemporaryFiles(for: id)
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

    // MARK: One transfer

    private func perform(_ id: String) async throws {
        guard var job = jobs[id] else { return }
        mutate(id) {
            $0.state = .preparing
            $0.pauseReason = nil
            $0.message = nil
            if $0.startedAt == nil { $0.startedAt = wallClock() }
        }

        try Self.validateSource(job)
        if job.sha256 == nil {
            let path = job.sourcePath
            let digest = try await Task.detached(priority: .utility) { try Self.sha256(ofFileAt: path) }.value
            try Task.checkCancellation()
            mutate(id) { $0.sha256 = digest }
            try Self.validateSource(job)
        }
        if pauseRequested.contains(id) { return pauseJob(id, reason: .user, message: nil) }

        let target = try await resolver.resolve(settings: settings)
        let phone = target.phone
        mutate(id) { $0.link = target.link }
        job = jobs[id] ?? job

        if target.link == .mobile && !job.allowMobileData {
            return pauseJob(
                id, reason: .mobileData,
                message: "Telefon je dostupný jen přes mobilní data. Přenos by je čerpal; potvrďte tlačítkem „Přesto poslat“, nebo zapněte Wi‑Fi."
            )
        }

        try await phone.makeDirectory(job.destinationDirectory)
        if job.destinationName == nil {
            let base = TransferNaming.sanitized(job.sourceName)
            var chosen: String?
            for attempt in 1...99 {
                let candidate = TransferNaming.candidate(base, attempt: attempt)
                if try await !phone.exists("\(job.destinationDirectory)/\(candidate)") { chosen = candidate; break }
            }
            guard let chosen else { throw TransferError.destinationBusy }
            mutate(id) { $0.destinationName = chosen }
            job = jobs[id] ?? job
        }

        let staging = PhoneStaging.directory(base: job.destinationDirectory, id: id)
        let part = "\(staging)/data.part"
        let remoteChunk = "\(staging)/chunk.tmp"
        try await phone.makeDirectory(staging)
        try await phone.removeStaging(remoteChunk)

        var existing = try await phone.size(of: part)
        if let current = existing, current > job.size {
            try await phone.removeStaging(part)
            existing = nil
        }
        if existing == nil { try await phone.truncate(part, to: 0) }
        var delivered = existing ?? 0

        let available = try await phone.freeBytes(at: job.destinationDirectory)
        let needed = job.size - delivered + reserveBytes
        if available < needed { throw TransferError.notEnoughSpace(needed: needed, available: available) }

        mutate(id) { $0.bytesDone = delivered; $0.state = .running }
        var meter = TransferSpeedMeter()
        meter.reset(at: monotonic(), bytes: delivered)
        meters[id] = meter
        sessionStart[id] = (monotonic(), delivered)
        publish()

        let source = URL(fileURLWithPath: job.sourcePath)
        let chunkSize = chunkSizeFor(target.link)
        while delivered < job.size {
            try Task.checkCancellation()
            if pauseRequested.contains(id) { return pauseJob(id, reason: .user, message: nil) }
            let length = min(chunkSize, job.size - delivered)
            let localChunk = try store.chunkURL(for: id)
            let offset = delivered
            try await Task.detached(priority: .utility) {
                try ChunkWriter.write(from: source, offset: offset, length: length, to: localChunk)
            }.value
            delivered = try await send(
                chunk: localChunk, remote: remoteChunk, part: part, phone: phone,
                previous: delivered, expected: delivered + length
            )
            store.removeTemporaryFiles(for: id)
            meters[id]?.add(bytes: delivered, at: monotonic())
            mutate(id) { $0.bytesDone = delivered }
        }

        mutate(id) { $0.state = .verifying }
        let remoteHash = try await phone.sha256(of: part)
        guard remoteHash == job.sha256 else {
            try? await phone.removeStaging(staging)
            mutate(id) { $0.bytesDone = 0 }
            throw TransferError.checksumMismatch
        }

        var finalName = job.destinationName ?? TransferNaming.sanitized(job.sourceName)
        var moved = false
        for attempt in 0..<20 {
            do {
                try await phone.move(part, to: "\(job.destinationDirectory)/\(finalName)")
                moved = true
                break
            } catch TransferError.destinationBusy {
                finalName = TransferNaming.candidate(TransferNaming.sanitized(job.sourceName), attempt: attempt + 2)
            }
        }
        guard moved else { throw TransferError.destinationBusy }
        try? await phone.removeStaging(staging)
        await phone.removeStagingRootIfEmpty(base: job.destinationDirectory)
        await phone.refreshMedia("\(job.destinationDirectory)/\(finalName)")

        let end = monotonic()
        let average = sessionStart[id].flatMap { start -> Double? in
            end > start.time ? Double(job.size - start.bytes) / (end - start.time) : nil
        }
        let finalNameCopy = finalName
        mutate(id) {
            $0.destinationName = finalNameCopy
            $0.bytesDone = $0.size
            $0.state = .completed
            $0.message = nil
            $0.finishedAt = wallClock()
            $0.averageBytesPerSecond = average
        }
    }

    /// Pushes one chunk and appends it; repairs the partial file when something goes wrong in between.
    private func send(
        chunk: URL, remote: String, part: String, phone: any PhoneFiles, previous: Int64, expected: Int64
    ) async throws -> Int64 {
        let length = expected - previous
        let timeout = max(60, 30 + Double(length) / 100_000)
        var lastError: Error = TransferError.timedOut
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                try await phone.push(local: chunk, to: remote, timeout: timeout)
                let size = try await phone.append(chunk: remote, to: part)
                if size == expected { return size }
                try await phone.truncate(part, to: previous)
                lastError = TransferError.sizeMismatch(expected: expected, actual: size)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // The append may have succeeded even though its reply was lost; the partial file's size tells.
                if let actual = try? await phone.size(of: part) {
                    if actual == expected { return actual }
                    if actual != previous { try? await phone.truncate(part, to: previous) }
                }
            }
            if attempt < 2 { try await Task.sleep(for: .seconds(retryDelay * Double(attempt + 1))) }
        }
        throw lastError
    }

    private func cleanupPhone(for job: TransferJob) async {
        let id = job.id
        let directory = job.destinationDirectory
        let resolver = resolver
        let settings = settings
        // Runs detached from the (possibly cancelled) calling task so the cleanup commands are not killed at once.
        await Task.detached {
            guard let target = try? await resolver.resolve(settings: settings) else { return }
            try? await target.phone.removeStaging(PhoneStaging.directory(base: directory, id: id))
            await target.phone.removeStagingRootIfEmpty(base: directory)
        }.value
    }

    // MARK: Source checks

    static func validateSource(_ job: TransferJob) throws {
        var info = stat()
        guard stat(job.sourcePath, &info) == 0 else { throw TransferError.invalidSource("Zdrojový soubor už neexistuje.") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw TransferError.invalidSource("Zdroj už není běžný soubor.") }
        guard Int64(info.st_size) == job.size, Double(info.st_mtimespec.tv_sec) == job.modifiedAt else {
            throw TransferError.invalidSource("Zdrojový soubor se od zařazení změnil. Přidejte ho znovu.")
        }
    }

    static func sha256(ofFileAt path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
