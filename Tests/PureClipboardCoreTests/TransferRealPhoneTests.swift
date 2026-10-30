import CryptoKit
import Foundation
import Testing
@testable import PureClipboardCore

/// Runs against a real phone, only when PURECLIPBOARD_REAL_PHONE=host:port is set. Sends one temporary file,
/// pauses it half way, resumes it, verifies it on the phone and deletes it again.
@Suite struct TransferRealPhoneTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PURECLIPBOARD_REAL_PHONE"] != nil))
    func pauseAndResumeOnARealPhone() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["PURECLIPBOARD_REAL_PHONE"])
        let adb = try #require(AdbLocator.find())
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("RealPhone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let name = "pcr-realtest-\(UUID().uuidString.prefix(8)).bin"
        var bytes = [UInt8](repeating: 0, count: 40_000_000)
        for index in 0..<bytes.count { bytes[index] = UInt8.random(in: 0...255) }
        let data = Data(bytes)
        let source = base.appendingPathComponent(name)
        try data.write(to: source)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let store = TransferStore(supportDirectory: base.appendingPathComponent("support"))
        let engine = TransferEngine(
            store: store, resolver: AdbPhoneResolver(adb: adb),
            settings: TransferSettings(endpoint: TransferSettings.normalizedEndpoint(endpoint)),
            chunkSizeFor: { _ in 4 * 1_048_576 }
        )
        await engine.enqueue(paths: [source.path])
        let id = try #require(await engine.currentJobs().first).id

        // Pause once a few chunks have landed.
        var waited = 0
        while waited < 600 {
            let job = try #require(await engine.currentJobs().first)
            if job.bytesDone >= 8 * 1_048_576 || job.state.isFinished { break }
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        await engine.pause(id)
        await engine.waitUntilIdle()
        var job = try #require(await engine.currentJobs().first)
        print("REAL: po pauze stav=\(job.state) doručeno=\(job.bytesDone)/\(job.size) cesta=\(String(describing: job.link))")
        #expect(job.state == .paused || job.state == .completed)

        if job.state == .paused {
            #expect(job.bytesDone > 0 && job.bytesDone < job.size)
            let before = job.bytesDone
            await engine.resume(id)
            await engine.waitUntilIdle()
            job = try #require(await engine.currentJobs().first)
            print("REAL: pokračováno od \(before), stav=\(job.state), průměr=\(job.averageBytesPerSecond.map { Int($0) } ?? 0) B/s")
        }
        #expect(job.state == .completed)

        let phone = AdbPhone(adb: adb, serial: TransferSettings.normalizedEndpoint(endpoint)!)
        let remote = "\(TransferSettings.defaultDestination)/\(try #require(job.destinationName))"
        let remoteHash = try await phone.sha256(of: remote)
        print("REAL: soubor na telefonu \(remote), sha256 sedí: \(remoteHash == expected)")
        #expect(remoteHash == expected)
        try await phone.removeFile(remote)
        #expect(try await !phone.exists(remote))
        #expect(try await !phone.exists("\(TransferSettings.defaultDestination)/\(PhoneStaging.folderName)"))
    }
}

extension AdbPhone {
    /// Test helper: deletes one plain file that this test created.
    func removeFile(_ path: String) async throws {
        _ = try await runner.run(adb, ["-s", serial, "shell", "rm -f \(ShellQuoting.quote(path))"], timeout: 30)
    }
}
