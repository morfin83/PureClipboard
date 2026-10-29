import Darwin
import Foundation

public enum ClaudeHookError: Error, Equatable, LocalizedError, Sendable {
    case settingsIsSymlink(String)
    case settingsInvalidJSON(String)
    case unexpectedStructure(String)
    case modifiedExternally
    case helperMissing(String)
    case io(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .settingsIsSymlink(let path):
            "Soubor nastavení Claude Code je symbolický odkaz (\(path)). Upravte jej ručně, aplikace jej nepřepíše."
        case .settingsInvalidJSON(let reason):
            "Nastavení Claude Code není platný JSON (\(reason)). Soubor nebyl změněn."
        case .unexpectedStructure(let reason):
            "Neočekávaná struktura nastavení Claude Code: \(reason). Soubor nebyl změněn."
        case .modifiedExternally:
            "Nastavení Claude Code se mezitím změnilo. Nic nebylo zapsáno, zkuste to znovu."
        case .helperMissing(let path):
            "Pomocný program hooku nebyl nalezen: \(path)"
        case .io(let reason):
            "Operace se souborem selhala: \(reason)."
        case .verificationFailed(let reason):
            "Kontrola po zápisu selhala (\(reason)). Původní soubor byl obnoven ze zálohy."
        }
    }
}

public struct ClaudeHookPaths: Equatable, Sendable {
    public var settings: URL
    /// Directory that also holds config.json (normally ~/Library/Application Support/PureClipboard).
    public var supportDirectory: URL

    public init(settings: URL, supportDirectory: URL) {
        self.settings = settings
        self.supportDirectory = supportDirectory
    }

    public var helper: URL { supportDirectory.appendingPathComponent("bin/pureclipboard-hook") }
    public var backups: URL { supportDirectory.appendingPathComponent("backups") }

    public static func standard(configURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeHookPaths {
        let settings: URL
        if let override = environment["PURECLIPBOARD_CLAUDE_SETTINGS_PATH"], !override.isEmpty {
            settings = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        }
        return ClaudeHookPaths(settings: settings, supportDirectory: configURL.deletingLastPathComponent())
    }
}

public struct ClaudeHookState: Equatable, Sendable {
    public var settingsExists = false
    public var settingsProblem: String?
    /// Number of Pure Clipboard handlers registered under hooks.Stop.
    public var registeredCount = 0
    public var helperInstalled = false
    /// nil when no bundled helper was supplied to compare against.
    public var helperMatchesBundled: Bool?
    public var hooksDisabled = false
    public var otherStopHandlers = 0

    public init() {}

    public var isRegistered: Bool { registeredCount > 0 }
}

public struct ClaudeHookReport: Equatable, Sendable {
    public var changed = false
    public var backup: URL?
    public var steps: [String] = []

    public init() {}
}

public struct ClaudeHookInstaller: Sendable {
    public static let helperName = "pureclipboard-hook"
    public static let hookArgument = "claude-stop"
    public static let timeoutSeconds = 15

    public let paths: ClaudeHookPaths

    public init(paths: ClaudeHookPaths) {
        self.paths = paths
    }

    // MARK: Pure JSON transforms

    static func command(for helper: URL) -> String {
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(hookArgument)"
    }

    /// Recognises handlers created by this app, whatever path the helper had when they were written.
    static func isOurs(_ command: String) -> Bool {
        guard command.hasSuffix(" \(hookArgument)") else { return false }
        return command.contains("/\(helperName)' ") || command.contains("/\(helperName) ")
    }

    private static func handlerCommand(_ value: JSONValue) -> String? {
        if case .object(let object) = value, case .string(let command)? = object["command"] { return command }
        return nil
    }

    static func adding(to root: JSONValue, command: String) throws(ClaudeHookError) -> (root: JSONValue, otherHandlers: Int) {
        guard case .object(var object) = root else { throw .unexpectedStructure("kořen není objekt") }

        var hooks: [String: JSONValue]
        switch object["hooks"] {
        case nil: hooks = [:]
        case .object(let value)?: hooks = value
        default: throw .unexpectedStructure("klíč „hooks“ není objekt")
        }
        var groups: [JSONValue]
        switch hooks["Stop"] {
        case nil: groups = []
        case .array(let value)?: groups = value
        default: throw .unexpectedStructure("klíč „hooks.Stop“ není pole")
        }

        let ours = JSONValue.object([
            "type": .string("command"),
            "command": .string(command),
            "timeout": .int(Int64(timeoutSeconds)),
        ])
        var placed = false
        var others = 0
        var rewritten: [JSONValue] = []
        for group in groups {
            guard case .object(var groupObject) = group else { throw .unexpectedStructure("položka v hooks.Stop není objekt") }
            guard let inner = groupObject["hooks"] else { rewritten.append(group); continue }
            guard case .array(let handlers) = inner else { throw .unexpectedStructure("pole „hooks“ ve skupině není pole") }
            var kept: [JSONValue] = []
            for handler in handlers {
                if let existing = handlerCommand(handler), isOurs(existing) {
                    if !placed { kept.append(ours); placed = true }
                } else {
                    kept.append(handler)
                    others += 1
                }
            }
            groupObject["hooks"] = .array(kept)
            rewritten.append(.object(groupObject))
        }
        if !placed { rewritten.append(.object(["hooks": .array([ours])])) }

        hooks["Stop"] = .array(rewritten)
        object["hooks"] = .object(hooks)
        return (.object(object), others)
    }

    /// Removes only this app's handlers. With `prune`, containers emptied by the removal are dropped too.
    static func removing(from root: JSONValue, prune: Bool) -> (root: JSONValue, removed: Int) {
        guard case .object(var object) = root,
              case .object(var hooks)? = object["hooks"],
              case .array(let groups)? = hooks["Stop"] else { return (root, 0) }

        var removed = 0
        var rewritten: [JSONValue] = []
        for group in groups {
            guard case .object(var groupObject) = group, case .array(let handlers)? = groupObject["hooks"] else {
                rewritten.append(group)
                continue
            }
            let kept = handlers.filter { handler in
                if let command = handlerCommand(handler), isOurs(command) { removed += 1; return false }
                return true
            }
            if kept.count == handlers.count { rewritten.append(group); continue }
            if kept.isEmpty && prune { continue }
            groupObject["hooks"] = .array(kept)
            rewritten.append(.object(groupObject))
        }
        guard removed > 0 else { return (root, 0) }

        if prune && rewritten.isEmpty { hooks["Stop"] = nil } else { hooks["Stop"] = .array(rewritten) }
        if prune && hooks.isEmpty { object["hooks"] = nil } else { object["hooks"] = .object(hooks) }
        return (.object(object), removed)
    }

    /// Canonical form used to prove that an edit changed nothing except this app's handlers.
    static func normalized(_ root: JSONValue) -> JSONValue {
        var value = removing(from: root, prune: true).root
        guard case .object(var object) = value else { return value }
        if case .object(var hooks)? = object["hooks"] {
            if case .array(let groups)? = hooks["Stop"], groups.isEmpty { hooks["Stop"] = nil }
            object["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        }
        value = .object(object)
        return value
    }

    // MARK: Reading

    private struct SettingsFile {
        var data: Data?
        var root: JSONValue
        var mode: mode_t
        var fingerprint: String?
    }

    private func lstatSettings() throws(ClaudeHookError) -> stat? {
        var info = stat()
        if lstat(paths.settings.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw .io(AtomicFile.errnoString())
    }

    private func readSettings() throws(ClaudeHookError) -> SettingsFile {
        guard let info = try lstatSettings() else {
            return SettingsFile(data: nil, root: .object([:]), mode: 0o600, fingerprint: nil)
        }
        let data: Data
        do { data = try Data(contentsOf: paths.settings) } catch { throw .io(error.localizedDescription) }
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw .settingsInvalidJSON(ConfigDocument.describe(error))
        }
        guard case .object = root else { throw .unexpectedStructure("kořen není objekt") }
        return SettingsFile(data: data, root: root, mode: info.st_mode & 0o777, fingerprint: ConfigFileStore.fingerprint(data))
    }

    public func state(bundledHelper: URL? = nil) -> ClaudeHookState {
        var state = ClaudeHookState()
        state.helperInstalled = FileManager.default.isExecutableFile(atPath: paths.helper.path)
        if state.helperInstalled, let bundledHelper,
           let installed = try? Data(contentsOf: paths.helper), let bundled = try? Data(contentsOf: bundledHelper) {
            state.helperMatchesBundled = installed == bundled
        }
        do {
            guard try lstatSettings() != nil else { return state }
            state.settingsExists = true
            let file = try readSettings()
            state.hooksDisabled = file.root["disableAllHooks"] == .bool(true)
            if case .object(let hooks)? = file.root["hooks"], case .array(let groups)? = hooks["Stop"] {
                for group in groups {
                    guard case .object(let groupObject) = group, case .array(let handlers)? = groupObject["hooks"] else { continue }
                    for handler in handlers {
                        if let command = Self.handlerCommand(handler), Self.isOurs(command) {
                            state.registeredCount += 1
                        } else {
                            state.otherStopHandlers += 1
                        }
                    }
                }
            }
        } catch {
            state.settingsProblem = error.localizedDescription
        }
        return state
    }

    // MARK: Install / uninstall

    @discardableResult
    public func install(bundledHelper: URL, dryRun: Bool = false) throws(ClaudeHookError) -> ClaudeHookReport {
        var report = ClaudeHookReport()
        if let info = try lstatSettings(), (info.st_mode & S_IFMT) == S_IFLNK {
            throw .settingsIsSymlink(paths.settings.path)
        }
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else {
            throw .helperMissing(bundledHelper.path)
        }

        let file = try readSettings()
        let command = Self.command(for: paths.helper)
        let (updated, others) = try Self.adding(to: file.root, command: command)
        let alreadyIdentical = updated == file.root
        let helperBytes: Data
        do { helperBytes = try Data(contentsOf: bundledHelper) } catch { throw .io(error.localizedDescription) }
        let helperCurrent = (try? Data(contentsOf: paths.helper)) == helperBytes

        if !helperCurrent { report.steps.append("Zkopíruje pomocný program do \(paths.helper.path)") }
        if alreadyIdentical {
            report.steps.append("Záznam hooku v \(paths.settings.path) už existuje beze změny")
        } else {
            if file.data != nil { report.steps.append("Zálohuje \(paths.settings.path) do \(paths.backups.path)") }
            report.steps.append("Přidá hook Stop do \(paths.settings.path) (stávající hooky ve Stop zůstanou: \(others))")
        }
        report.changed = !helperCurrent || !alreadyIdentical
        if dryRun || !report.changed { return report }

        do {
            if !helperCurrent {
                try AtomicFile.write(helperBytes, to: paths.helper, mode: 0o755)
            }
            guard !alreadyIdentical else { return report }

            if let original = file.data { report.backup = try backUp(original) }
            let newData = try encode(updated)

            // Last race check right before the rename.
            let latest = try readSettings()
            guard latest.fingerprint == file.fingerprint else { throw ClaudeHookError.modifiedExternally }

            try AtomicFile.write(newData, to: paths.settings, mode: file.mode, createDirectory: true)
            try verify(
                expected: Self.normalized(file.root),
                requireRegistered: 1,
                restore: file.data, backup: report.backup
            )
        } catch let error as ClaudeHookError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
        return report
    }

    @discardableResult
    public func uninstall(dryRun: Bool = false) throws(ClaudeHookError) -> ClaudeHookReport {
        var report = ClaudeHookReport()
        if let info = try lstatSettings(), (info.st_mode & S_IFMT) == S_IFLNK {
            throw .settingsIsSymlink(paths.settings.path)
        }
        let file = try readSettings()
        let (updated, removed) = Self.removing(from: file.root, prune: true)
        let helperPresent = FileManager.default.fileExists(atPath: paths.helper.path)

        if removed > 0 {
            report.steps.append("Zálohuje \(paths.settings.path) do \(paths.backups.path)")
            report.steps.append("Odebere \(removed) záznam(y) Pure Clipboard z hooks.Stop (ostatní hooky zůstanou)")
        }
        if helperPresent { report.steps.append("Smaže pomocný program \(paths.helper.path)") }
        report.changed = removed > 0 || helperPresent
        if dryRun || !report.changed { return report }

        do {
            if removed > 0, let original = file.data {
                report.backup = try backUp(original)
                let newData = try encode(updated)
                let latest = try readSettings()
                guard latest.fingerprint == file.fingerprint else { throw ClaudeHookError.modifiedExternally }
                try AtomicFile.write(newData, to: paths.settings, mode: file.mode, createDirectory: true)
                try verify(
                    expected: Self.normalized(file.root),
                    requireRegistered: 0,
                    restore: original, backup: report.backup
                )
            }
            if helperPresent { try FileManager.default.removeItem(at: paths.helper) }
        } catch let error as ClaudeHookError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
        return report
    }

    // MARK: Helpers

    private func encode(_ root: JSONValue) throws(ClaudeHookError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(root)
            data.append(0x0A)
            return data
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    private func backUp(_ original: Data) throws(ClaudeHookError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "claude-settings-\(formatter.string(from: Date()))-\(ConfigFileStore.fingerprint(original).prefix(8)).json"
        let url = paths.backups.appendingPathComponent(name)
        do {
            try AtomicFile.write(original, to: url, mode: 0o600)
        } catch {
            throw .io(error.localizedDescription)
        }
        return url
    }

    /// Re-reads the written file and proves it differs from the original only by this app's handler.
    /// On any mismatch the original bytes are put back.
    private func verify(expected: JSONValue, requireRegistered: Int, restore original: Data?, backup: URL?) throws(ClaudeHookError) {
        func rollback(_ reason: String) -> ClaudeHookError {
            if let original {
                try? AtomicFile.write(original, to: paths.settings, mode: 0o600)
            } else {
                try? FileManager.default.removeItem(at: paths.settings)
            }
            return .verificationFailed(reason)
        }
        let written: SettingsFile
        do { written = try readSettings() } catch { throw rollback(error.localizedDescription) }
        guard Self.normalized(written.root) == expected else { throw rollback("změnil se jiný obsah než hook") }
        var count = 0
        if case .object(let hooks)? = written.root["hooks"], case .array(let groups)? = hooks["Stop"] {
            for group in groups {
                guard case .object(let groupObject) = group, case .array(let handlers)? = groupObject["hooks"] else { continue }
                count += handlers.filter { Self.handlerCommand($0).map(Self.isOurs) ?? false }.count
            }
        }
        guard count == requireRegistered else { throw rollback("nesouhlasí počet záznamů hooku (\(count))") }
    }
}
