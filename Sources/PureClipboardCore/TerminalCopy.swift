import Foundation

/// Turns raw command output into plain text: no escape sequences, no carriage-return overwrites, no control characters.
public enum TerminalOutputSanitizer {
    public static func clean(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        for pattern in [
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",     // OSC (titles, hyperlinks)
            "\u{1B}\\[[0-?]*[ -/]*[@-~]",                       // CSI (colours, cursor movement)
            "\u{1B}[@-Z\\\\-_]",                                 // other two-byte escapes
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }
        // A carriage return rewrites the line (progress bars): keep what is visible at the end.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let last = line.lastIndex(of: "\r") { return line[line.index(after: last)...] }
                return line
            }
        let kept = lines.joined(separator: "\n").unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }
        var result = String(String.UnicodeScalarView(kept))
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}

/// Copies the output of one command that the user explicitly ran through the `pclip` wrapper.
/// Same gates and scanner as the agent hooks; fails closed on anything unexpected.
public struct TerminalCopyHandler {
    public static let maxInputBytes = 4 * 1024 * 1024
    public static let maxCopiedCharacters = 100_000

    public let store: ConfigFileStore
    public let clipboard: ClipboardWriting
    public let claims: ClipboardClaimStore?
    public let now: () -> Date

    public init(
        store: ConfigFileStore, clipboard: ClipboardWriting,
        claims: ClipboardClaimStore? = nil, now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.clipboard = clipboard
        self.claims = claims
        self.now = now
    }

    public func handle(output: Data, exitCode: Int32?, session: String) -> HookOutcome {
        let config: PureClipboardConfig
        do {
            config = try store.load().document.config
        } catch {
            return .skipped("config-unavailable", record: false)
        }
        guard config.global.autoCopy else { return .skipped("auto-copy-off", record: false) }
        guard config.integrations.terminal.enabled else { return .skipped("integration-off", record: false) }

        guard output.count <= Self.maxInputBytes else { return .skipped("payload-too-large") }
        let cleaned = TerminalOutputSanitizer.clean(output)
        guard !cleaned.isEmpty else { return .skipped("empty-message") }

        // The whole output is scanned, not just the part that would be copied.
        if config.global.protectSensitiveData {
            let findings = SensitiveDataScanner.scan(cleaned)
            guard findings.isEmpty else {
                return .skipped("sensitive-content", characters: cleaned.count, findings: findings)
            }
        }

        var text = cleaned
        if text.count > Self.maxCopiedCharacters {
            text = "… (zkráceno na posledních \(Self.maxCopiedCharacters) znaků)\n" + String(text.suffix(Self.maxCopiedCharacters))
        }
        if let exitCode, exitCode != 0 { text += "\n[exit \(exitCode)]" }

        let candidate = ClipboardClaimStore.Claim(source: IntegrationID.terminal.rawValue, session: session, time: now())
        guard let claims else { return write(text) }
        // An explicit user action is never blocked by a recent agent copy, but it claims the clipboard itself,
        // so an agent finishing a moment later cannot overwrite what the user just asked for.
        let outcome = claims.withLock { () -> HookOutcome in
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

    /// Dry run / real run with a harmless sample, for the "Test" buttons.
    public static func selfTest(store: ConfigFileStore, clipboard: ClipboardWriting) -> HookOutcome {
        TerminalCopyHandler(store: store, clipboard: clipboard)
            .handle(output: Data("Pure Clipboard – test výstupu z Terminálu (neškodný text).\n".utf8), exitCode: 0, session: "pure-clipboard-self-test")
    }
}
