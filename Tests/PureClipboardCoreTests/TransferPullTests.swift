import Foundation
import Testing
@testable import PureClipboardCore

private let phoneDownloads = "/sdcard/Download"

/// A phone-to-Mac test: the fake phone and a separate Mac folder for the finished files.
private final class PullLab: @unchecked Sendable {
    let lab: Lab
    let macFolder: URL

    init() throws {
        lab = try Lab()
        macFolder = lab.sources.deletingLastPathComponent().appendingPathComponent("Mac-Downloads")
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
    }

    func engine(resolver: (any PhoneResolving)? = nil) -> PullEngine {
        let folder = macFolder
        return PullEngine(
            store: lab.store, resolver: resolver ?? FakeResolver(phone: lab.phone), destination: { folder },
            retryDelay: 0, chunkSizeFor: { _ in Lab.chunk }
        )
    }

    /// Writes a file into the phone's Downloads folder and returns what the listing would show for it.
    func putOnPhone(_ name: String, bytes: Int = 3_500_000) throws -> (entry: PhoneFileEntry, data: Data) {
        var data = Data(count: bytes)
        for index in 0..<bytes { data[index] = UInt8(truncatingIfNeeded: index &* 17 &+ index >> 9) }
        let target = lab.phone.url("\(phoneDownloads)/\(name)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        let entry = PhoneFileEntry(
            name: name, path: "\(phoneDownloads)/\(name)", size: Int64(bytes),
            modifiedAt: Double(Int((try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as! Date).timeIntervalSince1970))
        )
        return (entry, data)
    }

    func macFile(_ name: String) -> Data? { try? Data(contentsOf: macFolder.appendingPathComponent(name)) }
    var macFileNames: [String] { (try? FileManager.default.contentsOfDirectory(atPath: macFolder.path)) ?? [] }
}

@Suite struct PullEngineTests {
    @Test func downloadsAnIdenticalFileAndLeavesThePhoneCopy() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        let result = await engine.enqueue([file.entry])
        #expect(result.added == 1)
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(job.direction == .pull)
        #expect(job.destinationName == "foto.jpg")
        #expect(job.sha256 != nil)
        #expect(pull.macFile("foto.jpg") == file.data)
        #expect(pull.lab.phone.readCount == 4)
        #expect(pull.lab.phone.has("\(phoneDownloads)/foto.jpg"))
        #expect(!FileManager.default.fileExists(atPath: try pull.lab.store.partialURL(for: job.id).path))
    }

    @Test func pauseKeepsThePartialFileAndResumeReadsOnlyTheRest() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        await engine.enqueue([file.entry])
        let id = try #require(await engine.currentJobs().first).id
        pull.lab.phone.onRead = { number in if number == 2 { await engine.pause(id) } }
        await engine.waitUntilIdle()

        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .user)
        #expect(job.bytesDone == 2 * Lab.chunk)
        #expect(pull.lab.phone.readCount == 2)
        let part = try pull.lab.store.partialURL(for: id)
        #expect(try Data(contentsOf: part).count == Int(2 * Lab.chunk))
        #expect(pull.macFile("foto.jpg") == nil)

        pull.lab.phone.onRead = nil
        await engine.resume(id)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(pull.lab.phone.readCount == 4)
        #expect(pull.macFile("foto.jpg") == file.data)
    }

    @Test func aNewEngineContinuesFromThePartialFile() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        let first = pull.engine()
        await first.enqueue([file.entry])
        let id = try #require(await first.currentJobs().first).id
        pull.lab.phone.onRead = { number in if number == 2 { await first.pause(id) } }
        await first.waitUntilIdle()

        // "App restart": a fresh engine on the same store.
        pull.lab.phone.onRead = nil
        let second = pull.engine()
        let loaded = try #require(await second.currentJobs().first)
        #expect(loaded.state == .paused)
        #expect(loaded.bytesDone == 2 * Lab.chunk)
        await second.resume(id)
        await second.waitUntilIdle()
        #expect(try #require(await second.currentJobs().first).state == .completed)
        #expect(pull.lab.phone.readCount == 4)
        #expect(pull.macFile("foto.jpg") == file.data)
    }

    @Test func aLostReplyIsAskedAgainForTheSameRange() async throws {
        let pull = try PullLab()
        pull.lab.phone.loseReplyOnRead = [2]
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()
        #expect(try #require(await engine.currentJobs().first).state == .completed)
        #expect(pull.lab.phone.readCount == 5)
        #expect(pull.macFile("foto.jpg") == file.data)
    }

    @Test func aFailingRangePausesWithAReasonAndContinuesFromTheLastPiece() async throws {
        let pull = try PullLab()
        pull.lab.phone.failReads = [2, 3, 4]
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()

        var job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .connectionLost)
        #expect(job.bytesDone == Lab.chunk)
        #expect(pull.macFile("foto.jpg") == nil)

        pull.lab.phone.failReads = []
        await engine.resume(job.id)
        await engine.waitUntilIdle()
        job = try #require(await engine.currentJobs().first)
        #expect(job.state == .completed)
        #expect(pull.macFile("foto.jpg") == file.data)
    }

    @Test func aWrongChecksumFailsAndNothingIsPlacedInTheDestination() async throws {
        let pull = try PullLab()
        pull.lab.phone.corruptHash = true
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .failed)
        #expect(pull.macFileNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try pull.lab.store.partialURL(for: job.id).path))
    }

    @Test func anExistingFileGetsANumberAndIsNeverOverwritten() async throws {
        let pull = try PullLab()
        try Data("stary".utf8).write(to: pull.macFolder.appendingPathComponent("foto.jpg"))
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.destinationName == "foto (2).jpg")
        #expect(pull.macFile("foto.jpg") == Data("stary".utf8))
        #expect(pull.macFile("foto (2).jpg") == file.data)
    }

    @Test func filesOutsideTheDownloadsFolderOrWithUnsafeNamesAreRejected() async throws {
        let pull = try PullLab()
        let engine = pull.engine()
        let outside = PhoneFileEntry(name: "foto.jpg", path: "/sdcard/DCIM/foto.jpg", size: 10, modifiedAt: 1)
        let traversal = PhoneFileEntry(name: "etc.jpg", path: "/sdcard/Download/../etc.jpg", size: 10, modifiedAt: 1)
        let slash = PhoneFileEntry(name: "a/b.jpg", path: "/sdcard/Download/a/b.jpg", size: 10, modifiedAt: 1)
        let result = await engine.enqueue([outside, traversal, slash])
        #expect(result.added == 0)
        #expect(result.rejected.count == 3)
        #expect(await engine.currentJobs().isEmpty)
    }

    @Test func aFileThatChangedAfterListingIsRefused() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        var stale = file.entry
        stale.modifiedAt -= 10
        let engine = pull.engine()
        await engine.enqueue([stale])
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .failed)
        #expect(pull.lab.phone.readCount == 0)
        #expect(pull.macFileNames.isEmpty)
    }

    @Test func aMissingPhonePausesWithAClearReason() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine(resolver: FakeResolver(phone: nil, failure: .noPhone("Telefon není připojený.")))
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .noPhone)
        #expect(pull.lab.phone.readCount == 0)
    }

    @Test func mobileDataNeedsConfirmationBeforeAnyRead() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine(resolver: FakeResolver(phone: pull.lab.phone, link: .mobile))
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()

        let job = try #require(await engine.currentJobs().first)
        #expect(job.state == .paused)
        #expect(job.pauseReason == .mobileData)
        #expect(pull.lab.phone.readCount == 0)
    }

    @Test func listingShowsOnlyPlainFilesOfTheDownloadsFolder() async throws {
        let pull = try PullLab()
        _ = try pull.putOnPhone("foto.jpg")
        _ = try pull.putOnPhone("zapis.pdf", bytes: 10)
        _ = try pull.putOnPhone(".skryty.jpg", bytes: 10)
        try FileManager.default.createDirectory(at: pull.lab.phone.url("\(phoneDownloads)/Slozka"), withIntermediateDirectories: true)
        let engine = pull.engine()
        let names = try await engine.listDownloads().map(\.name)
        #expect(Set(names) == ["foto.jpg", "zapis.pdf"])
    }

    @Test func pullsAndPushesDoNotSeeEachOthersJobs() async throws {
        let pull = try PullLab()
        let file = try pull.putOnPhone("foto.jpg")
        let engine = pull.engine()
        await engine.enqueue([file.entry])
        await engine.waitUntilIdle()

        let push = pull.lab.engine(resolver: FakeResolver(phone: pull.lab.phone))
        #expect(await push.currentJobs().isEmpty)
    }
}

@Suite struct PullSafetyTests {
    @Test func onlyPlainNamesDirectlyInsideDownloadsAreAllowed() {
        #expect(PullSafety.isAllowedSource("/sdcard/Download/foto.jpg"))
        #expect(PullSafety.isAllowedSource("/sdcard/Download/a b (2).jpg"))
        #expect(!PullSafety.isAllowedSource("/sdcard/DCIM/foto.jpg"))
        #expect(!PullSafety.isAllowedSource("/sdcard/Download/../foto.jpg"))
        #expect(!PullSafety.isAllowedSource("/sdcard/Download/sub/foto.jpg"))
        #expect(!PullSafety.isAllowedSource("/sdcard/Download/.pureclipboard"))
        #expect(!PullSafety.isAllowedSource("/sdcard/Download/"))
        #expect(!PullSafety.isAllowedSource("/sdcard/Download/x\ny.jpg"))
    }
}

@Suite struct TransferDirectionTests {
    @Test func jobsSavedBeforePullsDecodeAsPush() throws {
        let job = TransferJob(sourcePath: "/tmp/a", sourceName: "a", size: 5, modifiedAt: 1, destinationDirectory: "/sdcard/Download")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        object["direction"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: legacy)
        #expect(decoded.direction == .push)
        #expect(decoded == job)
    }

    @Test func aPullJobSurvivesARoundTrip() throws {
        let job = TransferJob(
            sourcePath: "/sdcard/Download/foto.jpg", sourceName: "foto.jpg", size: 5, modifiedAt: 1,
            destinationDirectory: "/Users/x/Downloads", direction: .pull
        )
        let decoded = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
        #expect(decoded.direction == .pull)
    }
}

// MARK: adb layer for pulls

private final class BinaryRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var text = ProcessResult(status: 0)
    var binary = BinaryResult(status: 0)

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { calls.append(arguments) }
        return text
    }

    func runBinary(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> BinaryResult {
        lock.withLock { calls.append(arguments) }
        return binary
    }
}

@Suite struct PullAdbLayerTests {
    @Test func readRangeQuotesThePathAndKeepsEveryByte() async throws {
        let runner = BinaryRunner()
        runner.binary = BinaryResult(status: 0, stdout: Data([0, 255, 10, 13]))
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        let data = try await phone.readRange("/sdcard/Download/it's.jpg", offset: 3, length: 4)
        #expect(data == Data([0, 255, 10, 13]))
        #expect(runner.calls.last == ["-s", "S", "exec-out", "tail -c +4 '/sdcard/Download/it'\\''s.jpg' | head -c 4"])
    }

    @Test func readRangeSeeksWithDdAtWholeMiB() async throws {
        let runner = BinaryRunner()
        runner.binary = BinaryResult(status: 0, stdout: Data([1, 2, 3]))
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        _ = try await phone.readRange("/sdcard/Download/a.bin", offset: 8_388_608, length: 4_194_304)
        #expect(runner.calls.last == ["-s", "S", "exec-out", "dd if='/sdcard/Download/a.bin' bs=1048576 skip=8 count=4 2>/dev/null | head -c 4194304"])
    }

    @Test func readRangeRefusesPathsOutsideDownloads() async throws {
        let runner = BinaryRunner()
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        await #expect(throws: TransferError.self) { try await phone.readRange("/sdcard/DCIM/x.jpg", offset: 0, length: 1) }
        await #expect(throws: TransferError.self) { try await phone.readRange("/sdcard/Download/../x.jpg", offset: 0, length: 1) }
        #expect(runner.calls.isEmpty)
    }

    @Test func readRangeReportsAFailedCommand() async throws {
        let runner = BinaryRunner()
        runner.binary = BinaryResult(status: 1, stderr: "no such file")
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        await #expect(throws: TransferError.self) { try await phone.readRange("/sdcard/Download/x.jpg", offset: 0, length: 1) }
    }

    @Test func listingParsesSizeTimeAndNameAndSkipsUnsafeNames() async throws {
        let runner = BinaryRunner()
        runner.text = ProcessResult(status: 0, stdout: """
        3500000|1700000000|/sdcard/Download/foto.jpg
        12|1700000100|/sdcard/Download/a|b.pdf
        5|1|/sdcard/Download/../x
        garbage line
        """)
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        let entries = try await phone.listFiles(in: "/sdcard/Download")
        #expect(entries.map(\.name) == ["a|b.pdf", "foto.jpg"])
        #expect(entries[1].size == 3_500_000)
        #expect(entries[1].modifiedAt == 1_700_000_000)
        #expect(runner.calls.last?.last?.contains("for f in '/sdcard/Download'/*") == true)
    }

    @Test func listingRefusesOtherFolders() async throws {
        let runner = BinaryRunner()
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        await #expect(throws: TransferError.self) { try await phone.listFiles(in: "/sdcard/DCIM") }
        #expect(runner.calls.isEmpty)
    }

    @Test func missingFileHasNoEntry() async throws {
        let runner = BinaryRunner()
        runner.text = ProcessResult(status: 0, stdout: "missing\n")
        let phone = AdbPhone(adb: "/x/adb", serial: "S", runner: runner)
        #expect(try await phone.entry(at: "/sdcard/Download/x.jpg") == nil)
    }
}
