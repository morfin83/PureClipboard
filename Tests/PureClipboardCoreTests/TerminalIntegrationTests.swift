import Foundation
import Testing
@testable import PureClipboardCore

private final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    var writes: [String] = []
    func write(_ text: String) -> Bool { writes.append(text); return true }
}

private final class Support: @unchecked Sendable {
    let dir: URL
    let store: ConfigFileStore
    init(autoCopy: Bool = true, terminal: Bool = true, protect: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCTerm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        var config = PureClipboardConfig.defaults
        config.global.autoCopy = autoCopy
        config.global.protectSensitiveData = protect
        config.integrations.terminal.enabled = terminal
        try store.save(ConfigDocument(config: config), expectedFingerprint: nil)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
    var claims: ClipboardClaimStore { ClipboardClaimStore(directory: dir) }
}

private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Suite struct TerminalOutputSanitizerTests {
    @Test func stripsColoursTitlesAndControlCharacters() {
        let raw = "\u{1B}[31mchyba\u{1B}[0m: \u{1B}]0;titulek\u{07}soubor\u{07}\u{00}\u{08}.swift\n"
        #expect(TerminalOutputSanitizer.clean(bytes(raw)) == "chyba: soubor.swift")
    }

    @Test func carriageReturnKeepsOnlyTheFinalVisibleLine() {
        let raw = "stahuji 10%\rstahuji 60%\rstahuji 100%\nhotovo\r\nkonec\n\n"
        #expect(TerminalOutputSanitizer.clean(bytes(raw)) == "stahuji 100%\nhotovo\nkonec")
    }

    @Test func keepsTabsNewlinesAndUnicode() {
        #expect(TerminalOutputSanitizer.clean(bytes("a\tb\nčeština ✓\n")) == "a\tb\nčeština ✓")
    }

    @Test func invalidUTF8DoesNotCrash() {
        #expect(!TerminalOutputSanitizer.clean(Data([0x68, 0xFF, 0xFE, 0x69])).isEmpty)
    }
}

@Suite struct TerminalCopyHandlerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func handler(_ s: Support, _ c: FakeClipboard, claims: Bool = false, now: Date? = nil) -> TerminalCopyHandler {
        TerminalCopyHandler(store: s.store, clipboard: c, claims: claims ? s.claims : nil, now: { now ?? Date() })
    }

    @Test func copiesCleanedOutput() throws {
        let s = try Support(); let c = FakeClipboard()
        let outcome = handler(s, c).handle(output: bytes("\u{1B}[32mOK\u{1B}[0m\nhotovo\n"), exitCode: 0, session: "tty-1")
        #expect(outcome.result == .copied)
        #expect(c.writes == ["OK\nhotovo"])
    }

    @Test func failingCommandGetsExitFooter() throws {
        let s = try Support(); let c = FakeClipboard()
        _ = handler(s, c).handle(output: bytes("error: boom\n"), exitCode: 2, session: "x")
        #expect(c.writes == ["error: boom\n[exit 2]"])
    }

    @Test func switchesAreRespected() throws {
        let master = try Support(autoCopy: false); let c = FakeClipboard()
        let a = handler(master, c).handle(output: bytes("text"), exitCode: 0, session: "x")
        #expect(a.reason == "auto-copy-off" && !a.shouldRecord)
        let off = try Support(terminal: false)
        let b = handler(off, c).handle(output: bytes("text"), exitCode: 0, session: "x")
        #expect(b.reason == "integration-off" && !b.shouldRecord)
        #expect(c.writes.isEmpty)
    }

    @Test func terminalSwitchIsIndependentOfOtherIntegrations() throws {
        let s = try Support(terminal: false); let c = FakeClipboard()
        var loaded = try s.store.load()
        loaded.document.config.integrations.claudeCode.enabled = true
        loaded.document.config.integrations.codex.enabled = true
        try s.store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        #expect(handler(s, c).handle(output: bytes("text"), exitCode: 0, session: "x").reason == "integration-off")
        #expect(c.writes.isEmpty)
    }

    @Test func brokenConfigFailsClosed() throws {
        let s = try Support(); let c = FakeClipboard()
        try Data("{ broken".utf8).write(to: s.store.url)
        #expect(handler(s, c).handle(output: bytes("text"), exitCode: 0, session: "x").reason == "config-unavailable")
        #expect(c.writes.isEmpty)
    }

    @Test func emptyAndWhitespaceOnlyOutputIsNotCopied() throws {
        let s = try Support(); let c = FakeClipboard()
        #expect(handler(s, c).handle(output: Data(), exitCode: 0, session: "x").reason == "empty-message")
        #expect(handler(s, c).handle(output: bytes("\u{1B}[0m \n\t\n"), exitCode: 0, session: "x").reason == "empty-message")
        #expect(c.writes.isEmpty)
    }

    @Test func sensitiveOutputIsBlockedEvenAfterColourCodes() throws {
        let s = try Support(); let c = FakeClipboard()
        let secret = "ghp_" + String(repeating: "Ab9", count: 12)
        let raw = "ok\n\u{1B}[1mGITHUB_TOKEN=\u{1B}[0m\(secret)\n"
        let outcome = handler(s, c).handle(output: bytes(raw), exitCode: 0, session: "x")
        #expect(outcome.reason == "sensitive-content")
        #expect(c.writes.isEmpty)
        HookEventRecord.write(outcome, besides: s.store.url, integration: .terminal)
        let log = try String(contentsOf: HookEventRecord.fileURL(besides: s.store.url, integration: .terminal), encoding: .utf8)
        #expect(!log.contains(secret) && !log.contains("GITHUB_TOKEN"))
    }

    @Test func secretInTheCutOffHeadStillBlocksTheCopy() throws {
        let s = try Support(); let c = FakeClipboard()
        let secret = "ghp_" + String(repeating: "Zy7", count: 12)
        let big = secret + "\n" + String(repeating: "řádek výstupu\n", count: 20_000)
        #expect(big.count > TerminalCopyHandler.maxCopiedCharacters)
        #expect(handler(s, c).handle(output: bytes(big), exitCode: 0, session: "x").reason == "sensitive-content")
        #expect(c.writes.isEmpty)
    }

    @Test func protectionOffCopiesWithoutScanning() throws {
        let s = try Support(protect: false); let c = FakeClipboard()
        let text = "password = " + "Tr0ub4dor&3x"
        #expect(handler(s, c).handle(output: bytes(text), exitCode: 0, session: "x").result == .copied)
        #expect(c.writes == [text])
    }

    @Test func longOutputKeepsTheTailWithMarker() throws {
        let s = try Support(); let c = FakeClipboard()
        let body = (1...30_000).map { "řádek \($0)" }.joined(separator: "\n")
        let outcome = handler(s, c).handle(output: bytes(body), exitCode: 1, session: "x")
        #expect(outcome.result == .copied)
        let copied = try #require(c.writes.first)
        #expect(copied.hasPrefix("… (zkráceno"))
        #expect(copied.contains("řádek 30000"))
        #expect(!copied.contains("řádek 1\n"))
        #expect(copied.hasSuffix("[exit 1]"))
    }

    @Test func hugeInputIsRejected() throws {
        let s = try Support(); let c = FakeClipboard()
        let huge = Data(repeating: 0x61, count: TerminalCopyHandler.maxInputBytes + 1)
        #expect(handler(s, c).handle(output: huge, exitCode: 0, session: "x").reason == "payload-too-large")
        #expect(c.writes.isEmpty)
    }

    @Test func explicitCopyIsNotBlockedButClaimsTheClipboard() throws {
        let s = try Support(); let c = FakeClipboard()
        s.claims.withLock { s.claims.record(.init(source: "codex", session: "agent", time: t0)) }
        let outcome = handler(s, c, claims: true, now: t0.addingTimeInterval(1)).handle(output: bytes("výstup"), exitCode: 0, session: "tty-9")
        #expect(outcome.result == .copied && c.writes == ["výstup"])
        #expect(s.claims.lastClaim()?.source == "terminal")

        // An agent finishing right afterwards must not overwrite what the user just asked for.
        let agent = StopHookHandler(store: s.store, clipboard: c, integration: .codex, claims: s.claims, now: { t0.addingTimeInterval(2) })
        var loaded = try s.store.load()
        loaded.document.config.integrations.codex.enabled = true
        try s.store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "agent", "last_assistant_message": "odpověď"])
        #expect(agent.handle(stdin: payload).reason == "recent-copy-by-other-session")
        #expect(c.writes == ["výstup"])
    }

    @Test func selfTestWorksAndRespectsSwitches() throws {
        let s = try Support(); let c = FakeClipboard()
        #expect(TerminalCopyHandler.selfTest(store: s.store, clipboard: c).result == .copied)
        #expect(SensitiveDataScanner.scan(c.writes[0]).isEmpty)
        let off = try Support(terminal: false)
        #expect(TerminalCopyHandler.selfTest(store: off.store, clipboard: FakeClipboard()).reason == "integration-off")
    }

    @Test func terminalEventRecordHasItsOwnFile() throws {
        let s = try Support(); let c = FakeClipboard()
        HookEventRecord.write(handler(s, c).handle(output: bytes("x"), exitCode: 0, session: "s"), besides: s.store.url, integration: .terminal)
        #expect(HookEventRecord.fileURL(besides: s.store.url, integration: .terminal).lastPathComponent == "last-event-terminal.json")
        #expect(HookEventRecord.read(besides: s.store.url, integration: .terminal)?.integration == "terminal")
    }
}

// MARK: zsh integration

private struct ZshEnv {
    let root: URL
    let paths: ZshIntegrationPaths
    let installer: ZshIntegrationInstaller
    let helperSource: URL

    init(zshrc: String? = nil, mode: Int = 0o644) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PCZsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = ZshIntegrationPaths(zshrc: root.appendingPathComponent("zshrc"), supportDirectory: root.appendingPathComponent("support"))
        installer = ZshIntegrationInstaller(paths: paths)
        helperSource = root.appendingPathComponent("helper-src")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperSource.path)
        if let zshrc {
            try Data(zshrc.utf8).write(to: paths.zshrc)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: paths.zshrc.path)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func zshrc() throws -> String { try String(contentsOf: paths.zshrc, encoding: .utf8) }
    func mode(_ url: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
}

private let userZshrc = """
# Created by `pipx`
export PATH="$PATH:/Users/x/.local/bin"

source "$HOME/.pure/bin/clipboard.zsh"

"""

@Suite struct ZshIntegrationTests {
    @Test func installAppendsOnlyAndKeepsEveryExistingLine() throws {
        let env = try ZshEnv(zshrc: userZshrc, mode: 0o644); defer { env.cleanup() }
        let report = try env.installer.install(bundledHelper: env.helperSource)
        let text = try env.zshrc()
        #expect(text.hasPrefix(userZshrc))
        #expect(text.contains(ZshIntegrationInstaller.beginMarker) && text.contains(ZshIntegrationInstaller.endMarker))
        let backup = try #require(report.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == userZshrc)
        #expect(try env.mode(backup) == 0o600)
        #expect(try env.mode(env.paths.zshrc) == 0o644)
        #expect(try env.mode(env.paths.helper) == 0o755)
        #expect(try env.mode(env.paths.snippet) == 0o600)
        let state = env.installer.state()
        #expect(state.isInstalled && state.snippetCurrent == true && state.helperInstalled)
    }

    @Test func installIsIdempotent() throws {
        let env = try ZshEnv(zshrc: userZshrc); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        let once = try env.zshrc()
        let report = try env.installer.install(bundledHelper: env.helperSource)
        #expect(!report.changed)
        #expect(try env.zshrc() == once)
        #expect(once.components(separatedBy: ZshIntegrationInstaller.beginMarker).count == 2)
    }

    @Test func uninstallRestoresTheOriginalFileExactly() throws {
        let env = try ZshEnv(zshrc: userZshrc); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        try env.installer.uninstall()
        #expect(try env.zshrc() == userZshrc)
        #expect(!FileManager.default.fileExists(atPath: env.paths.snippet.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.helper.path))
        #expect(!env.installer.state().isInstalled)
    }

    @Test func fileWithoutTrailingNewlineSurvivesRoundTrip() throws {
        let env = try ZshEnv(zshrc: "export A=1"); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        try env.installer.uninstall()
        #expect(try env.zshrc().trimmingCharacters(in: .whitespacesAndNewlines) == "export A=1")
    }

    @Test func missingZshrcIsCreatedAndRemovedCleanly() throws {
        let env = try ZshEnv(); defer { env.cleanup() }
        let report = try env.installer.install(bundledHelper: env.helperSource)
        #expect(report.backup == nil)
        #expect(try env.zshrc().hasPrefix(ZshIntegrationInstaller.beginMarker))
        #expect(try env.mode(env.paths.zshrc) == 0o644)
        try env.installer.uninstall()
        #expect(try env.zshrc().isEmpty)
    }

    @Test func dryRunWritesNothing() throws {
        let env = try ZshEnv(zshrc: userZshrc); defer { env.cleanup() }
        let report = try env.installer.install(bundledHelper: env.helperSource, dryRun: true)
        #expect(report.changed && !report.steps.isEmpty)
        #expect(try env.zshrc() == userZshrc)
        #expect(!FileManager.default.fileExists(atPath: env.paths.supportDirectory.path))
    }

    @Test(arguments: [
        "# >>> Pure Clipboard (Terminal) >>>\nfoo\n",
        "foo\n# <<< Pure Clipboard (Terminal) <<<\n",
        "# <<< Pure Clipboard (Terminal) <<<\nx\n# >>> Pure Clipboard (Terminal) >>>\n",
    ])
    func refusesBrokenMarkersAndLeavesFileAlone(raw: String) throws {
        let env = try ZshEnv(zshrc: raw); defer { env.cleanup() }
        #expect(throws: ClaudeHookError.self) { try env.installer.install(bundledHelper: env.helperSource) }
        #expect(throws: ClaudeHookError.self) { try env.installer.uninstall() }
        #expect(try env.zshrc() == raw)
        #expect(!FileManager.default.fileExists(atPath: env.paths.snippet.path))
    }

    @Test func refusesSymlinkedZshrc() throws {
        let env = try ZshEnv(); defer { env.cleanup() }
        let target = env.root.appendingPathComponent("real-zshrc")
        try Data("export A=1\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: env.paths.zshrc, withDestinationURL: target)
        #expect(throws: ClaudeHookError.self) { try env.installer.install(bundledHelper: env.helperSource) }
        #expect(throws: ClaudeHookError.self) { try env.installer.uninstall() }
        #expect(try String(contentsOf: target, encoding: .utf8) == "export A=1\n")
    }

    @Test func uninstallKeepsSharedHelperWhenAskedTo() throws {
        let env = try ZshEnv(zshrc: userZshrc); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        try env.installer.uninstall(removeHelper: false)
        #expect(FileManager.default.isExecutableFile(atPath: env.paths.helper.path))
        #expect(try env.zshrc() == userZshrc)
    }

    @Test func existingClipboardScriptIsNotedButNeverTouched() throws {
        let env = try ZshEnv(zshrc: userZshrc); defer { env.cleanup() }
        #expect(env.installer.state().notes.count == 1)
    }

    @Test func snippetIsValidZshAndStaleSnippetIsDetected() throws {
        let env = try ZshEnv(zshrc: userZshrc); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        let result = try runZsh(["-n", env.paths.snippet.path])
        #expect(result.status == 0, "\(result.err)")
        try Data("# old".utf8).write(to: env.paths.snippet)
        #expect(env.installer.state().snippetCurrent == false)
    }

    @Test func paramsOverrideStandardPaths() {
        let config = URL(fileURLWithPath: "/tmp/pc/config.json")
        let custom = ZshIntegrationPaths.standard(configURL: config, environment: ["PURECLIPBOARD_ZSHRC_PATH": "/tmp/z"])
        #expect(custom.zshrc.path == "/tmp/z" && custom.snippet.path == "/tmp/pc/shell/pureclipboard.zsh")
        #expect(ZshIntegrationPaths.standard(configURL: config, environment: [:]).zshrc.path.hasSuffix("/.zshrc"))
    }
}

// MARK: pclip behaviour in a real zsh

private func runZsh(_ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    for (k, v) in environment { env[k] = v }
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

@Suite struct PclipFunctionTests {
    /// A fake helper that records its arguments and stdin, so the wrapper can be tested without a clipboard.
    private func fixture() throws -> (dir: URL, helper: URL, snippet: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCPclip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let helper = dir.appendingPathComponent("helper")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(dir.path)/args'\ncat > '\(dir.path)/stdin'\nexit 7\n"
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let snippet = dir.appendingPathComponent("pclip.zsh")
        try Data(ZshIntegrationInstaller.renderSnippet(helper: helper).utf8).write(to: snippet)
        return (dir, helper, snippet)
    }

    @Test func passesThroughOutputAndExitCodeAndFeedsHelper() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let tmp = f.dir.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = try runZsh(["-f", "-c", "source '\(f.snippet.path)'; pclip sh -c 'echo ahoj; echo chyba >&2; exit 3'; print -r -- \"rc=$?\""],
                                environment: ["TMPDIR": tmp.path + "/"])
        #expect(result.out.contains("ahoj") && result.out.contains("chyba"))
        #expect(result.out.contains("rc=3"), "helper's own exit code (7) must never leak: \(result.out)")
        let args = try String(contentsOf: f.dir.appendingPathComponent("args"), encoding: .utf8)
        #expect(args.contains("terminal-copy") && args.contains("--exit") && args.contains("3") && args.contains("tty-"))
        let stdin = try String(contentsOf: f.dir.appendingPathComponent("stdin"), encoding: .utf8)
        #expect(stdin.contains("ahoj") && stdin.contains("chyba"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty, "temporary output file must be removed")
    }

    @Test func noArgumentsPrintsUsageAndReturns2() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let result = try runZsh(["-f", "-c", "source '\(f.snippet.path)'; pclip; print -r -- \"rc=$?\""])
        #expect(result.out.contains("rc=2") && result.err.contains("Použití"))
        #expect(!FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("args").path))
    }

    @Test func missingHelperStillRunsTheCommand() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        try FileManager.default.removeItem(at: f.helper)
        let result = try runZsh(["-f", "-c", "source '\(f.snippet.path)'; pclip sh -c 'echo stále běží; exit 4'; print -r -- \"rc=$?\""])
        #expect(result.out.contains("stále běží") && result.out.contains("rc=4"))
        #expect(result.err.contains("nebyl nalezen"))
    }

    @Test func commandWithSpacesAndQuotesIsPassedVerbatim() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.dir) }
        let result = try runZsh(["-f", "-c", "source '\(f.snippet.path)'; pclip printf '%s|' 'a b' \"c'd\" '$HOME'"])
        #expect(result.out.contains("a b|c'd|$HOME|"))
    }
}
