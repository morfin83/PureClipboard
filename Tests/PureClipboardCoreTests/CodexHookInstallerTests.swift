import Foundation
import Testing
@testable import PureClipboardCore

private struct Env {
    let root: URL
    let claudePaths: ClaudeHookPaths
    let codexPaths: ClaudeHookPaths
    let claude: ClaudeHookInstaller
    let codex: ClaudeHookInstaller
    let helperSource: URL

    init(hooksJSON: String? = nil, configToml: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PCCodexInstall-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codex")
        let claudeHome = root.appendingPathComponent("claude")
        for dir in [codexHome, claudeHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let support = root.appendingPathComponent("support")
        claudePaths = ClaudeHookPaths(settings: claudeHome.appendingPathComponent("settings.json"), supportDirectory: support)
        codexPaths = ClaudeHookPaths(settings: codexHome.appendingPathComponent("hooks.json"), supportDirectory: support)
        claude = ClaudeHookInstaller(paths: claudePaths, target: .claude)
        codex = ClaudeHookInstaller(paths: codexPaths, target: .codex)
        helperSource = root.appendingPathComponent("helper-src")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperSource.path)
        if let hooksJSON { try Data(hooksJSON.utf8).write(to: codexPaths.settings) }
        if let configToml { try Data(configToml.utf8).write(to: codexHome.appendingPathComponent("config.toml")) }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func json(_ url: URL) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) }
}

private func stopCommands(_ root: JSONValue) -> [String] {
    guard case .object(let hooks)? = root["hooks"], case .array(let groups)? = hooks["Stop"] else { return [] }
    return groups.flatMap { group -> [String] in
        guard case .array(let handlers)? = group["hooks"] else { return [] }
        return handlers.compactMap { if case .string(let c)? = $0["command"] { return c } else { return nil } }
    }
}

private let existingHooks = """
{
  "description": "Moje hooky",
  "futureKey": [1, 2, 3],
  "hooks": {
    "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "/usr/local/bin/hello" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/stop-sound", "timeout": 5 } ] } ]
  }
}
"""

@Suite struct CodexHookInstallerTests {
    @Test func targetsAreDistinctAndRecognisedSeparately() {
        let claudeCommand = ClaudeHookInstaller.command(for: URL(fileURLWithPath: "/a/bin/pureclipboard-hook"), target: .claude)
        let codexCommand = ClaudeHookInstaller.command(for: URL(fileURLWithPath: "/a/bin/pureclipboard-hook"), target: .codex)
        #expect(claudeCommand.hasSuffix(" claude-stop") && codexCommand.hasSuffix(" codex-stop"))
        #expect(ClaudeHookInstaller.isOurs(codexCommand, target: .codex))
        #expect(!ClaudeHookInstaller.isOurs(codexCommand, target: .claude))
        #expect(!ClaudeHookInstaller.isOurs(claudeCommand, target: .codex))
        #expect(HookTarget.codex.integration == .codex && HookTarget.claude.integration == .claudeCode)
    }

    @Test func freshInstallCreatesHooksJson() throws {
        let env = try Env(); defer { env.cleanup() }
        let report = try env.codex.install(bundledHelper: env.helperSource)
        #expect(report.changed && report.backup == nil)
        let commands = stopCommands(try env.json(env.codexPaths.settings))
        #expect(commands.count == 1 && commands[0].hasSuffix(" codex-stop"))
        let mode = try (FileManager.default.attributesOfItem(atPath: env.codexPaths.settings.path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
        #expect(env.codex.state().isRegistered && !env.claude.state().isRegistered)
    }

    @Test func existingHooksAreKeptAndBackedUpWithCodexPrefix() throws {
        let env = try Env(hooksJSON: existingHooks); defer { env.cleanup() }
        let before = try env.json(env.codexPaths.settings)
        let original = try Data(contentsOf: env.codexPaths.settings)
        let report = try env.codex.install(bundledHelper: env.helperSource)
        let backup = try #require(report.backup)
        #expect(backup.lastPathComponent.hasPrefix("codex-hooks-"))
        #expect(try Data(contentsOf: backup) == original)

        let after = try env.json(env.codexPaths.settings)
        #expect(after["description"] == before["description"] && after["futureKey"] == before["futureKey"])
        #expect(stopCommands(after).contains("/usr/local/bin/stop-sound"))
        #expect(stopCommands(after).count == 2)
        if case .object(let h)? = after["hooks"], case .object(let b)? = before["hooks"] {
            #expect(h["SessionStart"] == b["SessionStart"])
        } else { Issue.record("hooks missing") }
        #expect(env.codex.state().otherStopHandlers == 1)

        try env.codex.uninstall()
        #expect(try env.json(env.codexPaths.settings) == before)
    }

    @Test func installIsIdempotent() throws {
        let env = try Env(hooksJSON: existingHooks); defer { env.cleanup() }
        try env.codex.install(bundledHelper: env.helperSource)
        let once = try Data(contentsOf: env.codexPaths.settings)
        #expect(try !env.codex.install(bundledHelper: env.helperSource).changed)
        #expect(try Data(contentsOf: env.codexPaths.settings) == once)
    }

    @Test func claudeAndCodexShareOneHelperSafely() throws {
        let env = try Env(); defer { env.cleanup() }
        try env.claude.install(bundledHelper: env.helperSource)
        try env.codex.install(bundledHelper: env.helperSource)
        #expect(FileManager.default.isExecutableFile(atPath: env.claudePaths.helper.path))
        #expect(env.claudePaths.helper == env.codexPaths.helper)

        // Removing Claude while Codex is still registered must keep the shared helper.
        try env.claude.uninstall(removeHelper: !env.codex.state().isRegistered)
        #expect(FileManager.default.isExecutableFile(atPath: env.codexPaths.helper.path))
        #expect(env.codex.state().isRegistered && !env.claude.state().isRegistered)

        try env.codex.uninstall(removeHelper: !env.claude.state().isRegistered)
        #expect(!FileManager.default.fileExists(atPath: env.codexPaths.helper.path))
        #expect(try env.json(env.codexPaths.settings) == .object([:]))
    }

    @Test func eachInstallerIgnoresTheOthersEntries() throws {
        let env = try Env(); defer { env.cleanup() }
        let both = """
        {"hooks":{"Stop":[{"hooks":[
          {"type":"command","command":"'/x/bin/pureclipboard-hook' claude-stop"},
          {"type":"command","command":"'/x/bin/pureclipboard-hook' codex-stop"}]}]}}
        """
        try Data(both.utf8).write(to: env.codexPaths.settings)
        let state = env.codex.state()
        #expect(state.registeredCount == 1 && state.otherStopHandlers == 1)
        try env.codex.uninstall(removeHelper: false)
        #expect(stopCommands(try env.json(env.codexPaths.settings)) == ["'/x/bin/pureclipboard-hook' claude-stop"])
    }

    @Test func inlineHooksInConfigTomlAreReportedButNeverModified() throws {
        let toml = "notify = [\"/x/y\", \"turn-ended\"]\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"/bin/true\"\n"
        let env = try Env(configToml: toml); defer { env.cleanup() }
        let configURL = env.codexPaths.settings.deletingLastPathComponent().appendingPathComponent("config.toml")
        try env.codex.install(bundledHelper: env.helperSource)
        #expect(env.codex.state().notes.count == 1)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == toml)
    }

    @Test func plainConfigTomlHasNoNotesAndStaysUntouched() throws {
        let toml = "notify = [\"/x/y\", \"turn-ended\"]\nmodel = \"m\"\n"
        let env = try Env(configToml: toml); defer { env.cleanup() }
        let configURL = env.codexPaths.settings.deletingLastPathComponent().appendingPathComponent("config.toml")
        try env.codex.install(bundledHelper: env.helperSource)
        try env.codex.uninstall()
        #expect(env.codex.state().notes.isEmpty)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == toml)
    }

    @Test(arguments: ["{ nope", "[]", #"{"hooks":{"Stop":"x"}}"#])
    func refusesUnexpectedHooksJson(raw: String) throws {
        let env = try Env(hooksJSON: raw); defer { env.cleanup() }
        #expect(throws: ClaudeHookError.self) { try env.codex.install(bundledHelper: env.helperSource) }
        #expect(try String(contentsOf: env.codexPaths.settings, encoding: .utf8) == raw)
        #expect(!FileManager.default.fileExists(atPath: env.codexPaths.helper.path))
    }

    @Test func standardPathsHonourEnvironmentOverrides() {
        let config = URL(fileURLWithPath: "/tmp/pc/config.json")
        let codex = ClaudeHookPaths.standard(target: .codex, configURL: config, environment: ["PURECLIPBOARD_CODEX_HOOKS_PATH": "/tmp/h.json"])
        #expect(codex.settings.path == "/tmp/h.json" && codex.supportDirectory.path == "/tmp/pc")
        let defaults = ClaudeHookPaths.standard(target: .codex, configURL: config, environment: [:])
        #expect(defaults.settings.path.hasSuffix("/.codex/hooks.json"))
        let claude = ClaudeHookPaths.standard(configURL: config, environment: [:])
        #expect(claude.settings.path.hasSuffix("/.claude/settings.json"))
    }
}
