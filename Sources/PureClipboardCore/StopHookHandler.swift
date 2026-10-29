import AppKit
import Foundation

public enum PureClipboardVersion {
    public static let string = "0.3.0"
}

public protocol ClipboardWriting {
    /// Replaces the clipboard with `text`. Returns true only if the write was verified.
    func write(_ text: String) -> Bool
}

/// The real macOS general pasteboard.
public struct SystemClipboard: ClipboardWriting {
    public init() {}

    public func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        return pasteboard.string(forType: .string) == text
    }
}

/// Accepts everything and stores nothing; used for "would this be copied?" dry runs.
public struct DiscardingClipboard: ClipboardWriting {
    public init() {}
    public func write(_ text: String) -> Bool { true }
}

/// Outcome of one hook invocation. Contains rule names and counts only, never message content.
public struct HookOutcome: Equatable, Sendable {
    public enum Result: String, Sendable { case copied, skipped }

    public var result: Result
    public var reason: String
    public var characters: Int
    public var findings: [String]
    /// False for the cases where the integration is off or unusable: those must have no side effects at all.
    public var shouldRecord: Bool

    static func skipped(_ reason: String, record: Bool = true, characters: Int = 0, findings: [String] = []) -> HookOutcome {
        HookOutcome(result: .skipped, reason: reason, characters: characters, findings: findings, shouldRecord: record)
    }
}

/// Decides whether the final response of an agent turn may be copied, and copies it.
/// Everything unexpected fails closed: the clipboard is only touched when every check passes.
/// Used for both Claude Code and Codex: their `Stop` hooks deliver the same `last_assistant_message` field.
public struct StopHookHandler {
    public static let maxPayloadBytes = 4 * 1024 * 1024
    public static let maxMessageCharacters = 200_000

    private struct Payload: Decodable {
        var hook_event_name: String?
        var last_assistant_message: String?
        var session_id: String?
    }

    public let store: ConfigFileStore
    public let clipboard: ClipboardWriting
    public let integration: IntegrationID
    public let allowedEvents: Set<String>
    public let claims: ClipboardClaimStore?
    public let now: () -> Date

    public init(
        store: ConfigFileStore,
        clipboard: ClipboardWriting,
        integration: IntegrationID = .claudeCode,
        allowedEvents: Set<String> = ["Stop"],
        claims: ClipboardClaimStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.clipboard = clipboard
        self.integration = integration
        self.allowedEvents = allowedEvents
        self.claims = claims
        self.now = now
    }

    public func handle(stdin: Data) -> HookOutcome {
        let config: PureClipboardConfig
        do {
            config = try store.load().document.config
        } catch {
            return .skipped("config-unavailable", record: false)
        }
        guard config.global.autoCopy else { return .skipped("auto-copy-off", record: false) }
        guard config.integrations[integration].enabled else { return .skipped("integration-off", record: false) }

        guard stdin.count <= Self.maxPayloadBytes else { return .skipped("payload-too-large") }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: stdin) else {
            return .skipped("invalid-payload")
        }
        guard let event = payload.hook_event_name, allowedEvents.contains(event) else {
            return .skipped("unexpected-event")
        }
        guard let message = payload.last_assistant_message else { return .skipped("no-final-message") }

        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .skipped("empty-message") }
        guard text.count <= Self.maxMessageCharacters else { return .skipped("message-too-large", characters: text.count) }

        if config.global.protectSensitiveData {
            let findings = SensitiveDataScanner.scan(text)
            guard findings.isEmpty else {
                return .skipped("sensitive-content", characters: text.count, findings: findings)
            }
        }

        guard let claims else { return write(text) }

        let candidate = ClipboardClaimStore.Claim(
            source: integration.rawValue, session: payload.session_id ?? "unknown", time: now()
        )
        let outcome = claims.withLock { () -> HookOutcome in
            if claims.isBlocked(by: claims.lastClaim(), candidate: candidate) {
                return .skipped("recent-copy-by-other-session", characters: text.count)
            }
            let result = write(text)
            if result.result == .copied { claims.record(candidate) }
            return result
        }
        return outcome ?? .skipped("lock-unavailable", characters: text.count)
    }

    private func write(_ text: String) -> HookOutcome {
        guard clipboard.write(text) else { return .skipped("clipboard-write-failed", characters: text.count) }
        return HookOutcome(result: .copied, reason: "ok", characters: text.count, findings: [], shouldRecord: true)
    }
}

/// Kept for source compatibility with Milestone 2A.
public typealias ClaudeStopHandler = StopHookHandler

/// Runs the real decision logic on a harmless synthetic payload, as used by the "Test" buttons.
public enum HookSelfTest {
    public static let sampleText = "Pure Clipboard – test schránky (neškodný text)."

    public static func run(store: ConfigFileStore, integration: IntegrationID, clipboard: ClipboardWriting) -> HookOutcome {
        let payload: [String: Any] = [
            "hook_event_name": "Stop", "session_id": "pure-clipboard-self-test", "last_assistant_message": sampleText,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return .skipped("invalid-payload", record: false)
        }
        return StopHookHandler(store: store, clipboard: clipboard, integration: integration).handle(stdin: data)
    }
}

/// Metadata-only record of the latest hook run, shown by the app. Lives next to config.json, mode 0600.
public struct HookEventRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var integration: String
    public var result: String
    public var reason: String
    public var characters: Int
    public var findings: [String]

    /// Claude Code keeps the Milestone 2A file name; other integrations get their own file.
    public static func fileURL(besides config: URL, integration: IntegrationID = .claudeCode) -> URL {
        let name = integration == .claudeCode ? "last-event.json" : "last-event-\(integration.rawValue).json"
        return config.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func write(_ outcome: HookOutcome, besides config: URL, integration: IntegrationID = .claudeCode, now: Date = Date()) {
        guard outcome.shouldRecord else { return }
        let record = HookEventRecord(
            timestamp: now, integration: integration.rawValue, result: outcome.result.rawValue,
            reason: outcome.reason, characters: outcome.characters, findings: outcome.findings
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? AtomicFile.write(data, to: fileURL(besides: config, integration: integration), mode: 0o600)
    }

    public static func read(besides config: URL, integration: IntegrationID = .claudeCode) -> HookEventRecord? {
        guard let data = try? Data(contentsOf: fileURL(besides: config, integration: integration)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HookEventRecord.self, from: data)
    }
}
