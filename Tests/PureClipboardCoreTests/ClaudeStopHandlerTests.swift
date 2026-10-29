import Foundation
import Testing
@testable import PureClipboardCore

private final class FakeClipboard: ClipboardWriting {
    var writes: [String] = []
    var succeeds = true
    func write(_ text: String) -> Bool {
        guard succeeds else { return false }
        writes.append(text)
        return true
    }
}

private struct Fixture {
    let dir: URL
    let store: ConfigFileStore
    let clipboard = FakeClipboard()

    init(autoCopy: Bool = true, claude: Bool = true, protect: Bool = true, raw: String? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCHandler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        if let raw {
            try Data(raw.utf8).write(to: store.url)
        } else {
            var config = PureClipboardConfig.defaults
            config.global.autoCopy = autoCopy
            config.global.protectSensitiveData = protect
            config.integrations.claudeCode.enabled = claude
            try store.save(ConfigDocument(config: config), expectedFingerprint: nil)
        }
    }

    func run(_ json: String, events: Set<String> = ["Stop"]) -> HookOutcome {
        ClaudeStopHandler(store: store, clipboard: clipboard, allowedEvents: events).handle(stdin: Data(json.utf8))
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func payload(_ message: String?, event: String = "Stop", extra: String = "") -> String {
    var object: [String: Any] = ["hook_event_name": event, "session_id": "s", "cwd": "/tmp", "stop_hook_active": false]
    if let message { object["last_assistant_message"] = message }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self) + extra
}

@Suite struct ClaudeStopHandlerTests {
    @Test func copiesFinalMessageWhenBothSwitchesAreOn() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let outcome = f.run(payload("  Hotovo, vše funguje.\n"))
        #expect(outcome.result == .copied)
        #expect(f.clipboard.writes == ["Hotovo, vše funguje."])
        #expect(outcome.characters == 20)
    }

    @Test func masterSwitchOffDoesNothing() throws {
        let f = try Fixture(autoCopy: false); defer { f.cleanup() }
        let outcome = f.run(payload("text"))
        #expect(outcome.reason == "auto-copy-off")
        #expect(!outcome.shouldRecord)
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test func integrationSwitchOffDoesNothing() throws {
        let f = try Fixture(claude: false); defer { f.cleanup() }
        let outcome = f.run(payload("text"))
        #expect(outcome.reason == "integration-off")
        #expect(!outcome.shouldRecord)
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test func otherIntegrationsDoNotEnableClaude() throws {
        let f = try Fixture(claude: false); defer { f.cleanup() }
        var loaded = try f.store.load()
        loaded.document.config.integrations.codex.enabled = true
        loaded.document.config.integrations.terminal.enabled = true
        try f.store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        _ = f.run(payload("text"))
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test(arguments: [
        "{ not json",
        "[]",
        #"{"schemaVersion":1}"#,
        #"{"schemaVersion":1,"global":{"autoCopy":true,"historyLimit":0,"protectSensitiveData":true},"integrations":{}}"#,
    ])
    func brokenConfigFailsClosed(raw: String) throws {
        let f = try Fixture(raw: raw); defer { f.cleanup() }
        let outcome = f.run(payload("text"))
        #expect(outcome.reason == "config-unavailable")
        #expect(f.clipboard.writes.isEmpty)
        #expect(try String(contentsOf: f.store.url, encoding: .utf8) == raw)
    }

    @Test func missingConfigFailsClosed() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.store.url)
        #expect(f.run(payload("text")).reason == "config-unavailable")
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test func onlyConfiguredEventsAreAccepted() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for event in ["SubagentStop", "PostToolUse", "UserPromptSubmit", "SessionEnd", "StopFailure"] {
            #expect(f.run(payload("text", event: event)).reason == "unexpected-event")
        }
        #expect(f.clipboard.writes.isEmpty)
        #expect(f.run(payload("text", event: "SubagentStop"), events: ["Stop", "SubagentStop"]).result == .copied)
    }

    @Test func missingOrEmptyMessageIsNotCopied() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(f.run(payload(nil)).reason == "no-final-message")
        #expect(f.run(payload("   \n\t ")).reason == "empty-message")
        #expect(f.run(#"{"hook_event_name":"Stop","last_assistant_message":42}"#).reason == "invalid-payload")
        #expect(f.run(#"{"hook_event_name":"Stop","last_assistant_message":null}"#).reason == "no-final-message")
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test func garbagePayloadIsNotCopied() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for raw in ["", "nonsense", "[1,2]", "null", #"{"hook_event_name":"Stop"}"#] {
            #expect(f.run(raw).result == .skipped)
        }
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test func oversizedInputIsNotCopied() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let big = String(repeating: "a", count: ClaudeStopHandler.maxMessageCharacters + 1)
        #expect(f.run(payload(big)).reason == "message-too-large")
        let huge = Data(count: ClaudeStopHandler.maxPayloadBytes + 1)
        #expect(ClaudeStopHandler(store: f.store, clipboard: f.clipboard).handle(stdin: huge).reason == "payload-too-large")
        #expect(f.clipboard.writes.isEmpty)
    }

    @Test func sensitiveContentIsBlockedWithoutLeaking() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let secret = "ghp_" + String(repeating: "Qw7", count: 12)
        let outcome = f.run(payload("Tady je token: \(secret)"))
        #expect(outcome.result == .skipped)
        #expect(outcome.reason == "sensitive-content")
        #expect(outcome.findings.contains("github-token"))
        #expect(f.clipboard.writes.isEmpty)

        HookEventRecord.write(outcome, besides: f.store.url)
        let logged = try String(contentsOf: HookEventRecord.fileURL(besides: f.store.url), encoding: .utf8)
        #expect(!logged.contains(secret))
        #expect(!logged.contains("Tady je"))
    }

    @Test func protectionOffAllowsCopyingEverything() throws {
        let f = try Fixture(protect: false); defer { f.cleanup() }
        let text = "password = " + "Tr0ub4dor&3x"
        #expect(f.run(payload(text)).result == .copied)
        #expect(f.clipboard.writes == [text])
    }

    @Test func clipboardFailureIsReportedNotHidden() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.clipboard.succeeds = false
        let outcome = f.run(payload("text"))
        #expect(outcome.reason == "clipboard-write-failed")
        #expect(outcome.result == .skipped)
    }

    @Test func handlerNeverModifiesConfig() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = try Data(contentsOf: f.store.url)
        _ = f.run(payload("text"))
        _ = f.run(payload(nil))
        #expect(try Data(contentsOf: f.store.url) == before)
        let mode = try (FileManager.default.attributesOfItem(atPath: f.store.url.path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
    }

    @Test func eventRecordHasNoContentAndMode0600() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let outcome = f.run(payload("Důvěrná věta o ničem"))
        HookEventRecord.write(outcome, besides: f.store.url)
        let url = HookEventRecord.fileURL(besides: f.store.url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("Důvěrná"))
        #expect(HookEventRecord.read(besides: f.store.url)?.result == "copied")
        let mode = try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
    }

    @Test func disabledIntegrationLeavesNoTrace() throws {
        let f = try Fixture(claude: false); defer { f.cleanup() }
        HookEventRecord.write(f.run(payload("text")), besides: f.store.url)
        #expect(!FileManager.default.fileExists(atPath: HookEventRecord.fileURL(besides: f.store.url).path))
    }
}
