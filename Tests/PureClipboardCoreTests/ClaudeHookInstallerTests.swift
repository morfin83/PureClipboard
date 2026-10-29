import Foundation
import Testing
@testable import PureClipboardCore

private struct Env {
    let root: URL
    let paths: ClaudeHookPaths
    let installer: ClaudeHookInstaller
    let helperSource: URL

    init(settings: String? = nil, settingsMode: Int = 0o600) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PCInstall-\(UUID().uuidString)")
        let claude = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        paths = ClaudeHookPaths(
            settings: claude.appendingPathComponent("settings.json"),
            supportDirectory: root.appendingPathComponent("support")
        )
        installer = ClaudeHookInstaller(paths: paths)
        helperSource = root.appendingPathComponent("helper-src")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperSource.path)
        if let settings {
            try Data(settings.utf8).write(to: paths.settings)
            try FileManager.default.setAttributes([.posixPermissions: settingsMode], ofItemAtPath: paths.settings.path)
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func settingsData() throws -> Data { try Data(contentsOf: paths.settings) }
    func settingsJSON() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: settingsData()) }
    func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
}

private let richSettings = """
{
  "theme": "dark",
  "futureFlag": { "nested": [1, 2.5, null, true, "x"] },
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/audit" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-me", "timeout": 5 } ] } ]
  }
}
"""

private func stopHandlers(_ root: JSONValue) -> [JSONValue] {
    guard case .object(let hooks)? = root["hooks"], case .array(let groups)? = hooks["Stop"] else { return [] }
    return groups.flatMap { group -> [JSONValue] in
        if case .array(let handlers)? = group["hooks"] { return handlers }
        return []
    }
}

@Suite struct ClaudeHookInstallerTests {
    @Test func recognisesOnlyOwnCommands() {
        #expect(ClaudeHookInstaller.isOurs("'/a b/bin/pureclipboard-hook' claude-stop"))
        #expect(ClaudeHookInstaller.isOurs("/a/bin/pureclipboard-hook claude-stop"))
        #expect(!ClaudeHookInstaller.isOurs("/usr/bin/other claude-stop"))
        #expect(!ClaudeHookInstaller.isOurs("/a/bin/pureclipboard-hook status-claude"))
        #expect(!ClaudeHookInstaller.isOurs("echo pureclipboard-hook claude-stop"))
        #expect(!ClaudeHookInstaller.isOurs("/a/bin/pureclipboard-hook-evil claude-stop"))
    }

    @Test func commandQuotingSurvivesApostrophes() {
        let url = URL(fileURLWithPath: "/Users/o'brien/Application Support/bin/pureclipboard-hook")
        let command = ClaudeHookInstaller.command(for: url)
        #expect(command == #"'/Users/o'\''brien/Application Support/bin/pureclipboard-hook' claude-stop"#)
        #expect(ClaudeHookInstaller.isOurs(command))
    }

    @Test func freshInstallCreatesSettingsAndHelper() throws {
        let env = try Env(); defer { env.cleanup() }
        let report = try env.installer.install(bundledHelper: env.helperSource)
        #expect(report.changed)
        #expect(report.backup == nil)
        #expect(try stopHandlers(env.settingsJSON()).count == 1)
        #expect(try env.mode(env.paths.settings) == 0o600)
        #expect(try env.mode(env.paths.helper) == 0o755)
        #expect(try Data(contentsOf: env.paths.helper) == Data(contentsOf: env.helperSource))
        let state = env.installer.state(bundledHelper: env.helperSource)
        #expect(state.isRegistered && state.helperInstalled && state.helperMatchesBundled == true)
        #expect(state.otherStopHandlers == 0 && !state.hooksDisabled)
    }

    @Test func installKeepsEverythingElseAndBacksUp() throws {
        let env = try Env(settings: richSettings, settingsMode: 0o644); defer { env.cleanup() }
        let original = try env.settingsData()
        let originalJSON = try env.settingsJSON()

        let report = try env.installer.install(bundledHelper: env.helperSource)
        let backup = try #require(report.backup)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try env.mode(backup) == 0o600)
        #expect(try env.mode(env.paths.settings) == 0o644)

        let after = try env.settingsJSON()
        #expect(stopHandlers(after).count == 2)
        #expect(after["theme"] == originalJSON["theme"])
        #expect(after["futureFlag"] == originalJSON["futureFlag"])
        #expect(after["permissions"] == originalJSON["permissions"])
        if case .object(let hooks)? = after["hooks"], case .object(let before)? = originalJSON["hooks"] {
            #expect(hooks["PreToolUse"] == before["PreToolUse"])
        } else { Issue.record("hooks missing") }
        #expect(stopHandlers(after).first == stopHandlers(originalJSON).first)
        #expect(env.installer.state().otherStopHandlers == 1)
    }

    @Test func installIsIdempotent() throws {
        let env = try Env(settings: richSettings); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        let once = try env.settingsData()
        let report = try env.installer.install(bundledHelper: env.helperSource)
        #expect(!report.changed)
        #expect(try env.settingsData() == once)
        #expect(try stopHandlers(env.settingsJSON()).count == 2)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: env.paths.backups.path)) ?? []
        #expect(backups.count == 1)
    }

    @Test func reinstallFromNewLocationReplacesStaleEntry() throws {
        let env = try Env(settings: richSettings); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        let moved = ClaudeHookInstaller(paths: ClaudeHookPaths(
            settings: env.paths.settings, supportDirectory: env.root.appendingPathComponent("support2")))
        try moved.install(bundledHelper: env.helperSource)
        let ours = try stopHandlers(env.settingsJSON()).filter {
            if case .string(let c)? = $0["command"] { return ClaudeHookInstaller.isOurs(c) }
            return false
        }
        #expect(ours.count == 1)
        if case .string(let c)? = ours.first?["command"] { #expect(c.contains("support2")) }
    }

    @Test func uninstallRestoresOriginalStructure() throws {
        let env = try Env(settings: richSettings); defer { env.cleanup() }
        let originalJSON = try env.settingsJSON()
        try env.installer.install(bundledHelper: env.helperSource)
        let report = try env.installer.uninstall()
        #expect(report.backup != nil)
        #expect(try env.settingsJSON() == originalJSON)
        #expect(!FileManager.default.fileExists(atPath: env.paths.helper.path))
        #expect(!env.installer.state().isRegistered)
    }

    @Test func uninstallAfterFreshInstallLeavesEmptyObject() throws {
        let env = try Env(); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        try env.installer.uninstall()
        #expect(try env.settingsJSON() == .object([:]))
    }

    @Test func uninstallWithNothingInstalledChangesNothing() throws {
        let env = try Env(settings: richSettings); defer { env.cleanup() }
        let before = try env.settingsData()
        let report = try env.installer.uninstall()
        #expect(!report.changed)
        #expect(try env.settingsData() == before)
    }

    @Test func dryRunWritesNothing() throws {
        let env = try Env(settings: richSettings); defer { env.cleanup() }
        let before = try env.settingsData()
        let report = try env.installer.install(bundledHelper: env.helperSource, dryRun: true)
        #expect(report.changed && !report.steps.isEmpty)
        #expect(try env.settingsData() == before)
        #expect(!FileManager.default.fileExists(atPath: env.paths.helper.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.backups.path))
    }

    @Test(arguments: [
        "{ broken",
        "",
        "[]",
        #"{"hooks": []}"#,
        #"{"hooks": {"Stop": {}}}"#,
        #"{"hooks": {"Stop": [42]}}"#,
        #"{"hooks": {"Stop": [{"hooks": "x"}]}}"#,
    ])
    func refusesAndLeavesUnexpectedSettingsUntouched(raw: String) throws {
        let env = try Env(settings: raw); defer { env.cleanup() }
        #expect(throws: ClaudeHookError.self) { try env.installer.install(bundledHelper: env.helperSource) }
        #expect(try String(contentsOf: env.paths.settings, encoding: .utf8) == raw)
        #expect(!FileManager.default.fileExists(atPath: env.paths.helper.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.backups.path))
        #expect(env.installer.state().settingsProblem != nil || raw.contains("hooks"))
    }

    @Test func refusesSymlinkedSettings() throws {
        let env = try Env(); defer { env.cleanup() }
        let target = env.root.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: env.paths.settings, withDestinationURL: target)
        #expect(throws: ClaudeHookError.self) { try env.installer.install(bundledHelper: env.helperSource) }
        #expect(throws: ClaudeHookError.self) { try env.installer.uninstall() }
        #expect(try String(contentsOf: target, encoding: .utf8) == "{}")
        let attributes = try FileManager.default.attributesOfItem(atPath: env.paths.settings.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func refusesMissingHelperSource() throws {
        let env = try Env(settings: "{}"); defer { env.cleanup() }
        let missing = env.root.appendingPathComponent("nope")
        #expect(throws: ClaudeHookError.helperMissing(missing.path)) { try env.installer.install(bundledHelper: missing) }
        #expect(try String(contentsOf: env.paths.settings, encoding: .utf8) == "{}")
    }

    @Test func reportsDisabledHooksAndStaleHelper() throws {
        let env = try Env(settings: #"{"disableAllHooks": true}"#); defer { env.cleanup() }
        try env.installer.install(bundledHelper: env.helperSource)
        #expect(env.installer.state().hooksDisabled)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: env.helperSource)
        #expect(env.installer.state(bundledHelper: env.helperSource).helperMatchesBundled == false)
        let report = try env.installer.install(bundledHelper: env.helperSource)
        #expect(report.changed)
        #expect(env.installer.state(bundledHelper: env.helperSource).helperMatchesBundled == true)
    }

    @Test func removalLeavesForeignHandlersWithSimilarNames() throws {
        let raw = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/pureclipboard-hook-evil claude-stop"},
        {"type":"command","command":"/y/other claude-stop"}]}]}}
        """
        let env = try Env(settings: raw); defer { env.cleanup() }
        let before = try env.settingsJSON()
        let report = try env.installer.uninstall()
        #expect(!report.changed)
        #expect(try env.settingsJSON() == before)
    }
}
