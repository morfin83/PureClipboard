import CryptoKit
import Foundation
import Testing
@testable import PureClipboardCore

// MARK: Test doubles

/// A "phone" that is a folder on this Mac. Failures and hooks make the awkward cases deterministic.
final class FakePhone: PhoneFiles, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var _pushCount = 0
    private var _appendCount = 0
    private var _readCount = 0
    var failReads: Set<Int> = []
    var loseReplyOnRead: Set<Int> = []
    var onRead: (@Sendable (Int) async -> Void)?
    var readCount: Int { lock.withLock { _readCount } }
    var failPushes: Set<Int> = []
    var failAllPushesAfter: Int?
    var loseReplyOnAppend: Set<Int> = []
    var corruptHash = false
    var free: Int64 = 10 * 1_073_741_824
    var onPush: (@Sendable (Int) async -> Void)?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FakePhone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var pushCount: Int { lock.withLock { _pushCount } }
    var appendCount: Int { lock.withLock { _appendCount } }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func read(_ path: String) -> Data? { try? Data(contentsOf: url(path)) }
    func has(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    func freeBytes(at path: String) async throws -> Int64 { free }
    func exists(_ path: String) async throws -> Bool { has(path) }
    func size(of path: String) async throws -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url(path).path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
    func makeDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }
    func truncate(_ path: String, to size: Int64) async throws {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
    func push(local: URL, to remote: String, timeout: TimeInterval) async throws {
        let number = lock.withLock { () -> Int in _pushCount += 1; return _pushCount }
        await onPush?(number)
        if failPushes.contains(number) || (failAllPushesAfter.map { number > $0 } ?? false) {
            throw TransferError.commandFailed("simulovaný výpadek")
        }
        let target = url(remote)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: local, to: target)
    }
    func append(chunk: String, to file: String) async throws -> Int64 {
        let number = lock.withLock { () -> Int in _appendCount += 1; return _appendCount }
        let data = try Data(contentsOf: url(chunk))
        let target = url(file)
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.removeItem(at: url(chunk))
        if loseReplyOnAppend.contains(number) { throw TransferError.timedOut }
        return try await size(of: file) ?? 0
    }
    func listFiles(in folder: String) async throws -> [PhoneFileEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []
        var result: [PhoneFileEntry] = []
        for name in names where !name.hasPrefix(".") {
            if let found = try await entry(at: "\(folder)/\(name)") { result.append(found) }
        }
        return result
    }
    func entry(at path: String) async throws -> PhoneFileEntry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url(path).path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return PhoneFileEntry(
            name: String(path.split(separator: "/").last ?? ""), path: path,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, modifiedAt: Double(Int(modified))
        )
    }
    func readRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        let number = lock.withLock { () -> Int in _readCount += 1; return _readCount }
        await onRead?(number)
        if failReads.contains(number) { throw TransferError.commandFailed("simulovaný výpadek čtení") }
        let handle = try FileHandle(forReadingFrom: url(path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        // A lost reply: the bytes were produced on the phone, but the Mac never receives them.
        if loseReplyOnRead.contains(number) { throw TransferError.timedOut }
        return data
    }
    func sha256(of path: String) async throws -> String {
        guard let data = read(path) else { throw TransferError.commandFailed("chybí soubor") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return corruptHash ? String(hash.reversed()) : hash
    }
    func move(_ from: String, to: String) async throws {
        if has(to) { throw TransferError.destinationBusy }
        try FileManager.default.moveItem(at: url(from), to: url(to))
    }
    func removeStaging(_ path: String) async throws {
        guard PhoneStaging.isStagingPath(path) else { throw TransferError.commandFailed("mimo pracovní složku") }
        try? FileManager.default.removeItem(at: url(path))
    }
    var refreshed: [String] = []
    func refreshMedia(_ path: String) async { lock.withLock { refreshed.append(path) } }
    func removeStagingRootIfEmpty(base: String) async {
        let directory = url("\(base)/\(PhoneStaging.folderName)")
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

struct FakeResolver: PhoneResolving {
    let phone: FakePhone?
    var link: TransferLink = .wifi
    var failure: TransferError?
    func resolve(settings: TransferSettings) async throws -> PhoneTarget {
        if let failure { throw failure }
        return PhoneTarget(phone: phone!, link: link)
    }
}

private final class ResolverBox: PhoneResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: FakeResolver
    init(_ inner: FakeResolver) { self.inner = inner }
    func set(_ new: FakeResolver) { lock.withLock { inner = new } }
    func resolve(settings: TransferSettings) async throws -> PhoneTarget {
        let current = lock.withLock { inner }
        return try await current.resolve(settings: settings)
    }
}

final class Lab: @unchecked Sendable {
    let support: URL
    let sources: URL
    let store: TransferStore
    let phone: FakePhone

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TransferLab-\(UUID().uuidString)")
        support = base.appendingPathComponent("support")
        sources = base.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        store = TransferStore(supportDirectory: support)
        phone = try FakePhone()
    }

    deinit { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }

    static let chunk: Int64 = 1_048_576

    func engine(resolver: any PhoneResolving, link: TransferLink = .wifi) -> TransferEngine {
        TransferEngine(store: store, resolver: resolver, retryDelay: 0, chunkSizeFor: { _ in Lab.chunk })
    }

    func source(_ name: String = "foto.jpg", bytes: Int = 3_500_000) throws -> (path: String, data: Data) {
        var data = Data(count: bytes)
        for index in 0..<bytes { data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 8) }
        let url = sources.appendingPathComponent(name)
        try data.write(to: url)
        return (url.path, data)
    }
}

private let downloads = "/sdcard/Download"

// MARK: Transfers

@Suite struct TransferEngineTests {
    @Test func deliversAnIdenticalFileAndCleansUp() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(job.bytesDone == job.size)
        #expect(job.link == .wifi)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
        #expect(lab.phone.pushCount == 4)
        #expect(!lab.phone.has("\(downloads)/\(PhoneStaging.folderName)"))
    }

    @Test func pauseKeepsDeliveredBytesAndResumeDoesNotResend() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        let id = try #require(await engine.currentJobs().first).id
        lab.phone.onPush = { number in if number == 1 { await engine.pause(id) } }
        await engine.waitUntilIdle()

        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .user)
        #expect(job.bytesDone == Lab.chunk)
        #expect(lab.phone.pushCount == 1)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == nil)

        lab.phone.onPush = nil
        await engine.resume(id)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(lab.phone.pushCount == 4)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
    }

    @Test func aNewEngineContinuesWhereTheOldOneStopped() async throws {
        let lab = try Lab()
        let first = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await first.enqueue(paths: [file.path])
        let id = try #require(await first.currentJobs().first).id
        lab.phone.onPush = { number in if number == 2 { await first.pause(id) } }
        await first.waitUntilIdle()
        #expect(lab.phone.pushCount == 2)

        // "App restart": a fresh engine on the same store.
        lab.phone.onPush = nil
        let second = lab.engine(resolver: FakeResolver(phone: lab.phone))
        var job = try #require(await second.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.bytesDone == 2 * Lab.chunk)
        await second.resume(id)
        await second.waitUntilIdle()
        job = try #require(await second.currentJobs().first)
        #expect(job.state == .completed)
        #expect(lab.phone.pushCount == 4)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
    }

    @Test func aJobActiveAtCrashIsPausedNotResumedAutomatically() async throws {
        let lab = try Lab()
        let file = try lab.source()
        var job = TransferJob(
            sourcePath: file.path, sourceName: "foto.jpg", size: Int64(file.data.count),
            modifiedAt: Double(Int((try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date).timeIntervalSince1970)),
            destinationDirectory: downloads
        )
        job.state = .running
        job.bytesDone = 2 * Lab.chunk
        try lab.store.save(job)
        // Two chunks are really on the phone already.
        let staging = PhoneStaging.directory(base: downloads, id: job.id)
        try FileManager.default.createDirectory(at: lab.phone.url(staging), withIntermediateDirectories: true)
        try file.data.prefix(Int(2 * Lab.chunk)).write(to: lab.phone.url("\(staging)/data.part"))

        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let loaded = try #require(await engine.currentJobs().first)
        #expect(loaded.state == .paused)
        #expect(loaded.pauseReason == .interrupted)
        await engine.waitUntilIdle()
        #expect(lab.phone.pushCount == 0)

        await engine.resume(job.id)
        await engine.waitUntilIdle()
        #expect(lab.phone.pushCount == 2)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
    }

    @Test func aLostAppendReplyIsNotSentTwice() async throws {
        let lab = try Lab()
        lab.phone.loseReplyOnAppend = [2]
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        #expect(try #require(await engine.currentJobs().first).state == .completed)
        #expect(lab.phone.pushCount == 4)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
    }

    @Test func aFailedPushIsRetried() async throws {
        let lab = try Lab()
        lab.phone.failPushes = [2]
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        #expect(try #require(await engine.currentJobs().first).state == .completed)
        #expect(lab.phone.pushCount == 5)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
    }

    @Test func aDeadConnectionPausesAndResumesFromTheLastChunk() async throws {
        let lab = try Lab()
        lab.phone.failAllPushesAfter = 2
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()

        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .connectionLost)
        #expect(job.bytesDone == 2 * Lab.chunk)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == nil)

        lab.phone.failAllPushesAfter = nil
        await engine.resume(job.id)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(lab.phone.read("\(downloads)/foto.jpg") == file.data)
    }

    @Test func aWrongChecksumFailsWithoutLeavingAFile() async throws {
        let lab = try Lab()
        lab.phone.corruptHash = true
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .failed)
        #expect(job.message?.contains("Kontrolní součet") == true)
        #expect(!lab.phone.has("\(downloads)/foto.jpg"))
        #expect(!lab.phone.has(PhoneStaging.directory(base: downloads, id: job.id)))
    }

    @Test func neverOverwritesAnExistingFile() async throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.phone.url(downloads), withIntermediateDirectories: true)
        try Data("stará".utf8).write(to: lab.phone.url("\(downloads)/foto.jpg"))
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(job.destinationName == "foto (2).jpg")
        #expect(lab.phone.read("\(downloads)/foto.jpg") == Data("stará".utf8))
        #expect(lab.phone.read("\(downloads)/foto (2).jpg") == file.data)
    }

    @Test func mobileDataNeedsConfirmation() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone, link: .mobile))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .mobileData)
        #expect(lab.phone.pushCount == 0)

        await engine.resume(job.id, allowMobileData: true)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(job.link == .mobile)
    }

    @Test func missingPhonePausesWithAClearReason() async throws {
        let lab = try Lab()
        let box = ResolverBox(FakeResolver(phone: nil, failure: .noPhone("Telefon není připojený.")))
        let engine = lab.engine(resolver: box)
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .noPhone)
        #expect(job.message == "Telefon není připojený.")

        box.set(FakeResolver(phone: lab.phone))
        await engine.resume(job.id)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
    }

    @Test func cancelRemovesTheStagingFolder() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        let id = try #require(await engine.currentJobs().first).id
        lab.phone.onPush = { number in if number == 2 { await engine.cancel(id) } }
        await engine.waitUntilIdle()
        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .canceled)
        #expect(!lab.phone.has(PhoneStaging.directory(base: downloads, id: id)))
        #expect(lab.phone.read("\(downloads)/foto.jpg") == nil)
    }

    @Test func aChangedSourceFileIsRefused() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        // Same job, but the file is replaced afterwards and the job is resumed.
        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)

        let second = try lab.source("zmena.bin", bytes: 2_000_000)
        lab.phone.failAllPushesAfter = 0
        await engine.enqueue(paths: [second.path])
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().last)
        #expect(job.state == .paused)
        try Data(count: 10).write(to: URL(fileURLWithPath: second.path))
        lab.phone.failAllPushesAfter = nil
        await engine.resume(job.id)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().last)
        #expect(job.state == .failed)
        #expect(job.message?.contains("změnil") == true)
    }

    @Test func notEnoughSpaceFailsBeforeSendingAnything() async throws {
        let lab = try Lab()
        lab.phone.free = 1_000_000
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source()
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .failed)
        #expect(lab.phone.pushCount == 0)
    }

    @Test func anEmptyFileIsDelivered() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let file = try lab.source("prazdny.txt", bytes: 0)
        await engine.enqueue(paths: [file.path])
        await engine.waitUntilIdle()
        #expect(try #require(await engine.currentJobs().first).state == .completed)
        #expect(lab.phone.read("\(downloads)/prazdny.txt") == Data())
    }

    @Test func rejectsDirectoriesAndMissingFiles() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let result = await engine.enqueue(paths: [lab.sources.path, lab.sources.appendingPathComponent("nic").path])
        #expect(result.added == 0)
        #expect(result.rejected.count == 2)
        #expect(await engine.currentJobs().isEmpty)
    }

    @Test func queuedFilesAreSentOneAfterAnother() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let a = try lab.source("a.bin", bytes: 1_500_000)
        let b = try lab.source("b.bin", bytes: 1_200_000)
        await engine.enqueue(paths: [a.path, b.path])
        await engine.waitUntilIdle()
        #expect(lab.phone.read("\(downloads)/a.bin") == a.data)
        #expect(lab.phone.read("\(downloads)/b.bin") == b.data)
        #expect(await engine.currentJobs().allSatisfy { $0.state == .completed })
    }
}

// MARK: Small pieces

@Suite struct MediaIndexTests {
    @Test func onlyMediaFilesAreIndexed() {
        #expect(MediaFiles.needsIndexing("IMG_0001.JPG"))
        #expect(MediaFiles.needsIndexing("video.mov"))
        #expect(MediaFiles.needsIndexing("song.flac"))
        #expect(!MediaFiles.needsIndexing("Prezentace.pdf"))
        #expect(!MediaFiles.needsIndexing("README"))
    }

    @Test func adbBroadcastIsQuotedAndEncoded() async throws {
        let runner = RecordingRunner()
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        await phone.refreshMedia("/sdcard/Download/moje fotka.jpg")
        let command = try #require(runner.calls.last?.last)
        #expect(command.hasPrefix("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/Download/moje%20fotka.jpg'"))
        await phone.refreshMedia("/sdcard/Download/text.txt")
        #expect(runner.calls.count == 1)
    }

    @Test func engineAsksForIndexingOfTransferredMedia() async throws {
        let lab = try Lab()
        let engine = lab.engine(resolver: FakeResolver(phone: lab.phone))
        let photo = try lab.source("foto.jpg")
        let doc = try lab.source("doc.pdf", bytes: 1_000)
        await engine.enqueue(paths: [photo.path, doc.path])
        await engine.waitUntilIdle()
        #expect(lab.phone.refreshed == ["\(downloads)/foto.jpg", "\(downloads)/doc.pdf"])
    }
}

@Suite struct TransferPiecesTests {
    @Test func speedMeterUsesTheWindow() {
        var meter = TransferSpeedMeter(window: 8)
        meter.reset(at: 0, bytes: 0)
        #expect(meter.bytesPerSecond == 0)
        meter.add(bytes: 10_000_000, at: 2)
        #expect(meter.bytesPerSecond == 5_000_000)
        meter.add(bytes: 20_000_000, at: 4)
        #expect(meter.bytesPerSecond == 5_000_000)
        meter.add(bytes: 20_000_000, at: 20) // a long stall pulls the average down
        #expect(meter.bytesPerSecond < 2_000_000)
    }

    @Test func etaNeedsASpeed() {
        #expect(TransferSpeedMeter.eta(remaining: 10_000_000, bytesPerSecond: 5_000_000) == 2)
        #expect(TransferSpeedMeter.eta(remaining: 10, bytesPerSecond: 0) == nil)
    }

    @Test func chunkSizesFollowTheLink() {
        #expect(TransferLink.usb.chunkSize > TransferLink.wifi.chunkSize)
        #expect(TransferLink.wifi.chunkSize > TransferLink.mobile.chunkSize)
    }

    @Test func namingKeepsExtensionsAndNeverReturnsEmpty() {
        #expect(TransferNaming.candidate("foto.jpg", attempt: 1) == "foto.jpg")
        #expect(TransferNaming.candidate("foto.jpg", attempt: 3) == "foto (3).jpg")
        #expect(TransferNaming.candidate("README", attempt: 2) == "README (2)")
        #expect(TransferNaming.sanitized("a/b\nc") == "a_b_c")
        #expect(TransferNaming.sanitized("..") == "soubor")
        #expect(TransferNaming.sanitized("   ") == "soubor")
        let long = String(repeating: "š", count: 200) + ".jpg"
        let cleaned = TransferNaming.sanitized(long)
        #expect(cleaned.utf8.count <= 240)
        #expect(cleaned.hasSuffix(".jpg"))
    }

    @Test func endpointValidation() {
        #expect(TransferSettings.normalizedEndpoint("100.92.44.15") == "100.92.44.15:5555")
        #expect(TransferSettings.normalizedEndpoint(" 100.92.44.15:5556 ") == "100.92.44.15:5556")
        #expect(TransferSettings.normalizedEndpoint("[fd7a::1]:5555") == "[fd7a::1]:5555")
        #expect(TransferSettings.normalizedEndpoint("host; rm -rf /") == nil)
        #expect(TransferSettings.normalizedEndpoint("-s evil") == nil)
        #expect(TransferSettings.normalizedEndpoint("") == nil)
    }

    @Test func destinationMustStayInsideSharedStorage() {
        #expect(TransferSettings.isValidDestination("/sdcard/Download"))
        #expect(TransferSettings.isValidDestination("/sdcard/Pictures/Pure"))
        #expect(!TransferSettings.isValidDestination("/data/local/tmp"))
        #expect(!TransferSettings.isValidDestination("/sdcard/../data"))
        #expect(!TransferSettings.isValidDestination("/sdcard/a b"))
        #expect(!TransferSettings.isValidDestination("/sdcard/$(x)"))
    }

    @Test func shellQuotingNeutralisesMetacharacters() {
        #expect(ShellQuoting.quote("a b") == "'a b'")
        #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
        #expect(ShellQuoting.quote("$(rm -rf /); `x`") == "'$(rm -rf /); `x`'")
    }

    @Test func stagingPathGuard() {
        #expect(PhoneStaging.isStagingPath("/sdcard/Download/.pureclipboard/abc/data.part"))
        #expect(!PhoneStaging.isStagingPath("/sdcard/Download/foto.jpg"))
        #expect(!PhoneStaging.isStagingPath("/sdcard/Download/.pureclipboard/../foto.jpg"))
        #expect(!PhoneStaging.isStagingPath("/data/.pureclipboard/x"))
    }
}

@Suite struct TransferStoreTests {
    private func store() -> TransferStore {
        TransferStore(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TransferStore-\(UUID().uuidString)"))
    }

    @Test func jobsRoundTripWithPrivatePermissions() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        let job = TransferJob(sourcePath: "/tmp/a", sourceName: "a", size: 5, modifiedAt: 1, destinationDirectory: "/sdcard/Download")
        try store.save(job)
        #expect(store.loadJobs() == [job])
        let file = store.root.appendingPathComponent("jobs/\(job.id).json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        #expect(mode.intValue == 0o600)
        store.delete(job.id)
        #expect(store.loadJobs().isEmpty)
    }

    @Test func aCorruptJobFileIsSetAsideNotDeleted() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        let job = TransferJob(sourcePath: "/tmp/a", sourceName: "a", size: 5, modifiedAt: 1, destinationDirectory: "/sdcard/Download")
        try store.save(job)
        let file = store.root.appendingPathComponent("jobs/\(job.id).json")
        try Data("{ not json".utf8).write(to: file)
        #expect(store.loadJobs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
    }

    @Test func settingsFallBackToSafeDefaults() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        #expect(store.loadSettings() == TransferSettings())
        try store.save(TransferSettings(endpoint: "100.92.44.15:5555", destinationDirectory: "/data/evil"))
        let loaded = store.loadSettings()
        #expect(loaded.endpoint == "100.92.44.15:5555")
        #expect(loaded.destinationDirectory == TransferSettings.defaultDestination)
    }

    @Test func requestsFromTheHelperAreDrainedOnce() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root.deletingLastPathComponent()) }
        #expect(try store.enqueueRequest(paths: ["/tmp/a.jpg", "/tmp/b.jpg"]) == 2)
        #expect(try store.enqueueRequest(paths: ["/tmp/c.jpg"]) == 1)
        #expect(Set(store.drainRequests()) == ["/tmp/a.jpg", "/tmp/b.jpg", "/tmp/c.jpg"])
        #expect(store.drainRequests().isEmpty)
    }
}

// MARK: adb layer

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var responses: [(prefix: [String], result: ProcessResult)] = []

    /// Every prefix element must equal the argument, except the last, which only has to be a prefix of it.
    static func matches(_ arguments: [String], _ prefix: [String]) -> Bool {
        guard arguments.count >= prefix.count, let last = prefix.last else { return false }
        for (index, element) in prefix.dropLast().enumerated() where arguments[index] != element { return false }
        return arguments[prefix.count - 1].hasPrefix(last)
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { calls.append(arguments) }
        for response in responses where Self.matches(arguments, response.prefix) { return response.result }
        return ProcessResult(status: 0)
    }
}

@Suite struct AdbLayerTests {
    @Test func quotesEveryPathItPutsInAShellCommand() async throws {
        let runner = RecordingRunner()
        runner.responses = [(["-s", "S", "shell"], ProcessResult(status: 0, stdout: "1234\n"))]
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        _ = try await phone.append(chunk: "/sdcard/Download/.pureclipboard/i/chunk.tmp", to: "/sdcard/Download/.pureclipboard/i/data.part")
        let command = try #require(runner.calls.last?.last)
        #expect(command == "cat '/sdcard/Download/.pureclipboard/i/chunk.tmp' >> '/sdcard/Download/.pureclipboard/i/data.part' && rm -f '/sdcard/Download/.pureclipboard/i/chunk.tmp' && stat -c %s '/sdcard/Download/.pureclipboard/i/data.part'")

        let mover = RecordingRunner()
        mover.responses = [(["-s", "S", "shell"], ProcessResult(status: 0, stdout: "ok\n"))]
        try await AdbPhone(adb: "/x/adb", serial: "S", runner: mover).move("/a/it's", to: "/b/c d")
        #expect(mover.calls.last?.last == "if [ -e '/b/c d' ]; then echo busy; else mv '/a/it'\\''s' '/b/c d' && echo ok; fi")
    }

    @Test func movingNeverOverwrites() async throws {
        let runner = RecordingRunner()
        runner.responses = [(["-s", "S", "shell"], ProcessResult(status: 0, stdout: "busy\n"))]
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        await #expect(throws: TransferError.destinationBusy) { try await phone.move("/a", to: "/b") }
    }

    @Test func refusesToDeleteOutsideTheStagingFolder() async throws {
        let runner = RecordingRunner()
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        await #expect(throws: TransferError.self) { try await phone.removeStaging("/sdcard/Download/foto.jpg") }
        #expect(runner.calls.isEmpty)
    }

    @Test func parsesFreeSpaceAndSizes() async throws {
        let runner = RecordingRunner()
        runner.responses = [
            (["-s", "S", "shell", "df"], ProcessResult(status: 0, stdout: "/dev/fuse 479442944 252396088 226915784 53% /storage/emulated\n")),
            (["-s", "S", "shell", "stat"], ProcessResult(status: 0, stdout: "missing\n")),
        ]
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        #expect(try await phone.freeBytes(at: "/sdcard") == 226_915_784 * 1_024)
        #expect(try await phone.size(of: "/sdcard/x") == nil)
    }

    @Test func parsesTheDeviceList() {
        let output = """
        List of devices attached
        R5CY1234ABC\tdevice usb:1-1 product:pa2qxeea
        100.92.44.15:5555\tunauthorized
        * daemon started successfully
        """
        let devices = AdbPhoneResolver.parseDevices(output)
        #expect(devices.map(\.serial) == ["R5CY1234ABC", "100.92.44.15:5555"])
        #expect(devices[0].isNetwork == false)
        #expect(devices[1].isNetwork == true)
        #expect(devices[1].state == "unauthorized")
    }

    @Test func prefersTheCableOverWireless() async throws {
        let runner = RecordingRunner()
        runner.responses = [(["devices"], ProcessResult(status: 0, stdout: "List of devices attached\n100.92.44.15:5555\tdevice\nR5CY1\tdevice\n"))]
        let resolver = AdbPhoneResolver(adb: "/x/adb", runner: runner)
        let target = try await resolver.resolve(settings: TransferSettings(endpoint: "100.92.44.15:5555"))
        #expect(target.link == .usb)
        #expect(!runner.calls.contains { $0.first == "connect" })
    }

    @Test func detectsMobileDataWhenWifiIsOff() async throws {
        let runner = RecordingRunner()
        runner.responses = [
            (["devices"], ProcessResult(status: 0, stdout: "List of devices attached\n100.92.44.15:5555\tdevice\n")),
            (["-s", "100.92.44.15:5555", "shell", "cmd wifi status | head -n 1"], ProcessResult(status: 0, stdout: "Wifi is disabled\n")),
        ]
        let resolver = AdbPhoneResolver(adb: "/x/adb", runner: runner)
        let target = try await resolver.resolve(settings: TransferSettings(endpoint: "100.92.44.15:5555"))
        #expect(target.link == .mobile)
        #expect(runner.calls.contains { $0 == ["connect", "100.92.44.15:5555"] })
    }

    @Test func explainsWhyThereIsNoPhone() async throws {
        let runner = RecordingRunner()
        runner.responses = [(["devices"], ProcessResult(status: 0, stdout: "List of devices attached\n"))]
        let resolver = AdbPhoneResolver(adb: "/x/adb", runner: runner)
        await #expect(throws: TransferError.self) { try await resolver.resolve(settings: TransferSettings()) }
        await #expect(throws: TransferError.self) { try await resolver.resolve(settings: TransferSettings(endpoint: "10.0.0.5:5555")) }
    }
}
