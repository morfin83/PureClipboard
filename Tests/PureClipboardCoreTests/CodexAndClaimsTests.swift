import Darwin
import Foundation
import Testing
@testable import PureClipboardCore

private final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    var writes: [String] = []
    var succeeds = true
    func write(_ text: String) -> Bool {
        guard succeeds else { return false }
        writes.append(text)
        return true
    }
}

private final class TempSupport: @unchecked Sendable {
    let dir: URL
    let store: ConfigFileStore
    init(autoCopy: Bool = true, claude: Bool = false, codex: Bool = true, protect: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCCodex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        var config = PureClipboardConfig.defaults
        config.global.autoCopy = autoCopy
        config.global.protectSensitiveData = protect
        config.integrations.claudeCode.enabled = claude
        config.integrations.codex.enabled = codex
        try store.save(ConfigDocument(config: config), expectedFingerprint: nil)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    var claims: ClipboardClaimStore { ClipboardClaimStore(directory: dir) }

    func handler(_ integration: IntegrationID, _ clipboard: FakeClipboard, now: @escaping () -> Date = Date.init, claims: Bool = true) -> StopHookHandler {
        StopHookHandler(store: store, clipboard: clipboard, integration: integration, claims: claims ? self.claims : nil, now: now)
    }
}

private func payload(_ message: String?, session: String? = "s1", event: String = "Stop") -> Data {
    var object: [String: Any] = ["hook_event_name": event, "turn_id": "t", "cwd": "/tmp", "stop_hook_active": false]
    if let message { object["last_assistant_message"] = message }
    if let session { object["session_id"] = session }
    return try! JSONSerialization.data(withJSONObject: object)
}

@Suite struct CodexHandlerTests {
    @Test func codexCopiesWhenItsOwnSwitchIsOn() throws {
        let t = try TempSupport(claude: false, codex: true)
        let clip = FakeClipboard()
        let outcome = t.handler(.codex, clip).handle(stdin: payload("Odpověď Codexu"))
        #expect(outcome.result == .copied)
        #expect(clip.writes == ["Odpověď Codexu"])
    }

    @Test func switchesAreIndependent() throws {
        let t = try TempSupport(claude: true, codex: false)
        let clip = FakeClipboard()
        let codex = t.handler(.codex, clip).handle(stdin: payload("text"))
        #expect(codex.reason == "integration-off" && !codex.shouldRecord)
        #expect(clip.writes.isEmpty)
        #expect(t.handler(.claudeCode, clip).handle(stdin: payload("text")).result == .copied)

        let u = try TempSupport(claude: false, codex: true)
        let clip2 = FakeClipboard()
        #expect(u.handler(.claudeCode, clip2).handle(stdin: payload("text")).reason == "integration-off")
        #expect(clip2.writes.isEmpty)
    }

    @Test func masterSwitchOffStopsCodexToo() throws {
        let t = try TempSupport(autoCopy: false)
        let clip = FakeClipboard()
        #expect(t.handler(.codex, clip).handle(stdin: payload("text")).reason == "auto-copy-off")
        #expect(clip.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: t.claims.claimURL.path))
    }

    @Test func codexBlocksSensitiveContent() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        let secret = "sk-" + String(repeating: "aB3x", count: 8)
        let outcome = t.handler(.codex, clip).handle(stdin: payload("klíč \(secret)"))
        #expect(outcome.reason == "sensitive-content")
        #expect(clip.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: t.claims.claimURL.path))
    }

    @Test func codexNullOrMissingMessageIsNotCopied() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        #expect(t.handler(.codex, clip).handle(stdin: payload(nil)).reason == "no-final-message")
        let json = #"{"hook_event_name":"Stop","session_id":"s","last_assistant_message":null}"#
        #expect(t.handler(.codex, clip).handle(stdin: Data(json.utf8)).reason == "no-final-message")
        #expect(t.handler(.codex, clip).handle(stdin: payload("x", event: "SubagentStop")).reason == "unexpected-event")
        #expect(clip.writes.isEmpty)
    }

    @Test func eventRecordsAreSeparatePerIntegration() throws {
        let t = try TempSupport(claude: true, codex: true)
        let clip = FakeClipboard()
        HookEventRecord.write(t.handler(.codex, clip, claims: false).handle(stdin: payload("a")), besides: t.store.url, integration: .codex)
        #expect(HookEventRecord.read(besides: t.store.url, integration: .codex)?.integration == "codex")
        #expect(HookEventRecord.read(besides: t.store.url, integration: .claudeCode) == nil)
        #expect(HookEventRecord.fileURL(besides: t.store.url).lastPathComponent == "last-event.json")
        #expect(HookEventRecord.fileURL(besides: t.store.url, integration: .codex).lastPathComponent == "last-event-codex.json")
        let mode = try (FileManager.default.attributesOfItem(
            atPath: HookEventRecord.fileURL(besides: t.store.url, integration: .codex).path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
    }
}

@Suite struct ClipboardClaimsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func otherSessionCannotOverwriteWithinWindow() throws {
        let t = try TempSupport(claude: true, codex: true)
        let clip = FakeClipboard()
        #expect(t.handler(.codex, clip, now: { t0 }).handle(stdin: payload("první", session: "A")).result == .copied)
        let second = t.handler(.codex, clip, now: { t0.addingTimeInterval(2) }).handle(stdin: payload("druhá", session: "B"))
        #expect(second.reason == "recent-copy-by-other-session")
        #expect(clip.writes == ["první"])
        // The loser did not take over the claim: the original owner keeps it.
        #expect(t.claims.lastClaim()?.session == "A")
    }

    @Test func differentIntegrationIsAlsoProtected() throws {
        let t = try TempSupport(claude: true, codex: true)
        let clip = FakeClipboard()
        _ = t.handler(.claudeCode, clip, now: { t0 }).handle(stdin: payload("claude", session: "same"))
        let outcome = t.handler(.codex, clip, now: { t0.addingTimeInterval(1) }).handle(stdin: payload("codex", session: "same"))
        #expect(outcome.reason == "recent-copy-by-other-session")
        #expect(clip.writes == ["claude"])
    }

    @Test func sameSessionMayCopyAgainImmediately() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        _ = t.handler(.codex, clip, now: { t0 }).handle(stdin: payload("a", session: "A"))
        #expect(t.handler(.codex, clip, now: { t0.addingTimeInterval(0.5) }).handle(stdin: payload("b", session: "A")).result == .copied)
        #expect(clip.writes == ["a", "b"])
    }

    @Test func otherSessionMayCopyAfterWindow() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        _ = t.handler(.codex, clip, now: { t0 }).handle(stdin: payload("a", session: "A"))
        let later = t0.addingTimeInterval(ClipboardClaimStore.defaultWindow + 0.1)
        #expect(t.handler(.codex, clip, now: { later }).handle(stdin: payload("b", session: "B")).result == .copied)
        #expect(clip.writes == ["a", "b"])
        #expect(t.claims.lastClaim()?.session == "B")
    }

    @Test func missingSessionIdsAreTreatedAsOneAnonymousSession() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        _ = t.handler(.codex, clip, now: { t0 }).handle(stdin: payload("a", session: nil))
        #expect(t.handler(.codex, clip, now: { t0.addingTimeInterval(1) }).handle(stdin: payload("b", session: nil)).result == .copied)
        #expect(t.handler(.codex, clip, now: { t0.addingTimeInterval(2) }).handle(stdin: payload("c", session: "named")).reason == "recent-copy-by-other-session")
    }

    @Test func failedWriteDoesNotClaimTheClipboard() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        clip.succeeds = false
        #expect(t.handler(.codex, clip, now: { t0 }).handle(stdin: payload("a", session: "A")).reason == "clipboard-write-failed")
        #expect(t.claims.lastClaim() == nil)
        clip.succeeds = true
        #expect(t.handler(.codex, clip, now: { t0.addingTimeInterval(1) }).handle(stdin: payload("b", session: "B")).result == .copied)
    }

    @Test func claimFileIsPrivateAndCorruptionIsHarmless() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        _ = t.handler(.codex, clip, now: { t0 }).handle(stdin: payload("a", session: "A"))
        let mode = try (FileManager.default.attributesOfItem(atPath: t.claims.claimURL.path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
        try Data("garbage".utf8).write(to: t.claims.claimURL)
        #expect(t.claims.lastClaim() == nil)
        #expect(t.handler(.codex, clip, now: { t0.addingTimeInterval(1) }).handle(stdin: payload("b", session: "B")).result == .copied)
    }

    @Test func clockGoingBackwardsDoesNotBlockForever() {
        let store = ClipboardClaimStore(directory: FileManager.default.temporaryDirectory)
        let last = ClipboardClaimStore.Claim(source: "codex", session: "A", time: t0)
        let earlier = ClipboardClaimStore.Claim(source: "codex", session: "B", time: t0.addingTimeInterval(-60))
        #expect(!store.isBlocked(by: last, candidate: earlier))
        #expect(!store.isBlocked(by: nil, candidate: earlier))
    }

    @Test func heldLockMakesHookFailClosed() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        try FileManager.default.createDirectory(at: t.dir, withIntermediateDirectories: true)
        let fd = open(t.claims.lockURL.path, O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let outcome = t.handler(.codex, clip).handle(stdin: payload("a"))
        #expect(outcome.reason == "lock-unavailable")
        #expect(clip.writes.isEmpty)
    }

    @Test func concurrentWritersProduceExactlyOneCopy() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        let results = LockedBox<[String]>([])
        let group = DispatchGroup()
        for index in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                let handler = StopHookHandler(
                    store: t.store, clipboard: clip, integration: .codex, claims: t.claims, now: { Date() })
                let outcome = handler.handle(stdin: payload("zpráva \(index)", session: "S\(index)"))
                results.append(outcome.reason)
                group.leave()
            }
        }
        group.wait()
        let values = results.value
        #expect(values.filter { $0 == "ok" }.count == 1)
        #expect(values.filter { $0 == "recent-copy-by-other-session" }.count == 7)
        #expect(clip.writes.count == 1)
    }
}

@Suite struct HookSelfTestTests {
    @Test func dryRunReportsWouldCopyWithoutTouchingClipboard() throws {
        let t = try TempSupport()
        let clip = FakeClipboard()
        let outcome = HookSelfTest.run(store: t.store, integration: .codex, clipboard: clip)
        #expect(outcome.result == .copied)
        #expect(clip.writes == [HookSelfTest.sampleText])
    }

    @Test func selfTestRespectsSwitches() throws {
        let t = try TempSupport(claude: false, codex: false)
        #expect(HookSelfTest.run(store: t.store, integration: .codex, clipboard: FakeClipboard()).reason == "integration-off")
        let off = try TempSupport(autoCopy: false)
        #expect(HookSelfTest.run(store: off.store, integration: .codex, clipboard: FakeClipboard()).reason == "auto-copy-off")
    }

    @Test func sampleTextPassesTheScanner() {
        #expect(SensitiveDataScanner.scan(HookSelfTest.sampleText).isEmpty)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
}

extension LockedBox where Value == [String] {
    func append(_ element: String) { lock.lock(); storage.append(element); lock.unlock() }
}
