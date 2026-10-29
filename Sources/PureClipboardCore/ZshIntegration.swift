import Darwin
import Foundation

public struct ZshIntegrationPaths: Equatable, Sendable {
    public var zshrc: URL
    public var supportDirectory: URL

    public init(zshrc: URL, supportDirectory: URL) {
        self.zshrc = zshrc
        self.supportDirectory = supportDirectory
    }

    public var snippet: URL { supportDirectory.appendingPathComponent("shell/pureclipboard.zsh") }
    public var helper: URL { supportDirectory.appendingPathComponent("bin/pureclipboard-hook") }
    public var backups: URL { supportDirectory.appendingPathComponent("backups") }

    public static func standard(configURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ZshIntegrationPaths {
        let zshrc: URL
        if let override = environment["PURECLIPBOARD_ZSHRC_PATH"], !override.isEmpty {
            zshrc = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        }
        return ZshIntegrationPaths(zshrc: zshrc, supportDirectory: configURL.deletingLastPathComponent())
    }
}

public struct ZshIntegrationState: Equatable, Sendable {
    public var zshrcExists = false
    public var problem: String?
    public var blockPresent = false
    public var snippetInstalled = false
    /// nil when the snippet is not installed.
    public var snippetCurrent: Bool?
    public var helperInstalled = false
    public var notes: [String] = []

    public init() {}

    public var isInstalled: Bool { blockPresent && snippetInstalled }
}

/// Opt-in terminal integration: a `pclip` zsh function in a file of our own, loaded by one marked block in `~/.zshrc`.
/// Existing lines of `.zshrc` are never modified; install only appends the block, uninstall only removes it.
public struct ZshIntegrationInstaller: Sendable {
    public static let beginMarker = "# >>> Pure Clipboard (Terminal) >>>"
    public static let endMarker = "# <<< Pure Clipboard (Terminal) <<<"
    public static let functionName = "pclip"

    public let paths: ZshIntegrationPaths

    public init(paths: ZshIntegrationPaths) {
        self.paths = paths
    }

    // MARK: Pure text transforms

    static var block: String {
        """
        \(beginMarker)
        # Přidává příkaz \(functionName); odstraníte jej v aplikaci Pure Clipboard nebo smazáním tohoto bloku.
        [ -r "$HOME/Library/Application Support/PureClipboard/shell/pureclipboard.zsh" ] && source "$HOME/Library/Application Support/PureClipboard/shell/pureclipboard.zsh"
        \(endMarker)
        """
    }

    /// The loader line points at the standard location; a custom support directory is baked into the snippet instead.
    static func renderSnippet(helper: URL) -> String {
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        # Pure Clipboard – integrace Terminálu (generováno aplikací Pure Clipboard \(PureClipboardVersion.string)).
        # Příkaz `\(functionName) příkaz [argumenty…]` spustí příkaz, zobrazí jeho výstup a po skončení
        # ho zkopíruje do schránky, pokud to dovoluje nastavení Pure Clipboard (Auto Copy + Terminal)
        # a výstup neobsahuje citlivé údaje. Nic jiného se v terminálu nesleduje.
        \(functionName)() {
          emulate -L zsh
          if (( $# == 0 )); then
            print -u2 "Použití: \(functionName) příkaz [argumenty...]"
            return 2
          fi
          local helper=\(quoted)
          if [[ ! -x $helper ]]; then
            print -u2 "\(functionName): pomocný program Pure Clipboard nebyl nalezen; spouštím příkaz bez kopírování."
            "$@"
            return $?
          fi
          local tmp rc
          tmp=$(mktemp "${TMPDIR:-/tmp/}pureclip.XXXXXX") || { "$@"; return $?; }
          {
            "$@" 2>&1 | tee "$tmp"
            rc=${pipestatus[1]}
            "$helper" terminal-copy --exit "$rc" --session "tty-$$" < "$tmp"
          } always {
            rm -f "$tmp"
          }
          return $rc
        }

        """
    }

    static func hasBlock(_ text: String) throws(ClaudeHookError) -> Bool {
        let begins = text.components(separatedBy: beginMarker).count - 1
        let ends = text.components(separatedBy: endMarker).count - 1
        if begins == 0 && ends == 0 { return false }
        guard begins == 1, ends == 1, let b = text.range(of: beginMarker), let e = text.range(of: endMarker), b.lowerBound < e.lowerBound else {
            throw .unexpectedStructure("v .zshrc je neúplný nebo zdvojený blok Pure Clipboard")
        }
        return true
    }

    static func adding(to text: String) throws(ClaudeHookError) -> String {
        if try hasBlock(text) { return try replacingBlock(in: text, with: block) }
        var result = text
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + block + "\n"
    }

    static func removing(from text: String) throws(ClaudeHookError) -> String {
        guard try hasBlock(text) else { return text }
        var result = try replacingBlock(in: text, with: "")
        // Drop the blank separator line that install added, if still there.
        result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result == "\n" ? "" : result
    }

    private static func replacingBlock(in text: String, with replacement: String) throws(ClaudeHookError) -> String {
        guard let b = text.range(of: beginMarker), let e = text.range(of: endMarker) else {
            throw .unexpectedStructure("chybí značky bloku")
        }
        var end = e.upperBound
        if end < text.endIndex, text[end] == "\n" { end = text.index(after: end) }
        let tail = replacement.isEmpty ? String(text[end...]) : replacement + "\n" + String(text[end...])
        return String(text[..<b.lowerBound]) + tail
    }

    // MARK: State

    private func lstatZshrc() throws(ClaudeHookError) -> stat? {
        var info = stat()
        if lstat(paths.zshrc.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw .io(AtomicFile.errnoString())
    }

    public func state(bundledHelper: URL? = nil) -> ZshIntegrationState {
        var state = ZshIntegrationState()
        state.helperInstalled = FileManager.default.isExecutableFile(atPath: paths.helper.path)
        if let installed = try? String(contentsOf: paths.snippet, encoding: .utf8) {
            state.snippetInstalled = true
            state.snippetCurrent = installed == Self.renderSnippet(helper: paths.helper)
        }
        do {
            guard try lstatZshrc() != nil else { return state }
            state.zshrcExists = true
            let text = try String(contentsOf: paths.zshrc, encoding: .utf8)
            state.blockPresent = try Self.hasBlock(text)
            if text.contains("clipboard.zsh") && !state.blockPresent {
                state.notes.append("V .zshrc už načítáte vlastní clipboard.zsh; zůstane beze změny a funguje vedle příkazu \(Self.functionName).")
            }
        } catch {
            state.problem = error.localizedDescription
        }
        return state
    }

    // MARK: Install / uninstall

    @discardableResult
    public func install(bundledHelper: URL, dryRun: Bool = false) throws(ClaudeHookError) -> ClaudeHookReport {
        var report = ClaudeHookReport()
        if let info = try lstatZshrc(), (info.st_mode & S_IFMT) == S_IFLNK { throw .settingsIsSymlink(paths.zshrc.path) }
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else { throw .helperMissing(bundledHelper.path) }

        let original: String?
        let mode: mode_t
        if let info = try lstatZshrc() {
            do { original = try String(contentsOf: paths.zshrc, encoding: .utf8) } catch { throw .io(error.localizedDescription) }
            mode = info.st_mode & 0o777
        } else {
            original = nil
            mode = 0o644
        }
        let updated = try Self.adding(to: original ?? "")
        let zshrcChanged = updated != original
        let helperBytes: Data
        do { helperBytes = try Data(contentsOf: bundledHelper) } catch { throw .io(error.localizedDescription) }
        let helperCurrent = (try? Data(contentsOf: paths.helper)) == helperBytes
        let snippet = Self.renderSnippet(helper: paths.helper)
        let snippetCurrent = (try? String(contentsOf: paths.snippet, encoding: .utf8)) == snippet

        if !helperCurrent { report.steps.append("Zkopíruje pomocný program do \(paths.helper.path)") }
        if !snippetCurrent { report.steps.append("Vytvoří soubor s příkazem \(Self.functionName): \(paths.snippet.path)") }
        if zshrcChanged {
            if original != nil { report.steps.append("Zálohuje \(paths.zshrc.path) do \(paths.backups.path)") }
            report.steps.append("Na konec \(paths.zshrc.path) připíše blok Pure Clipboard (4 řádky; stávající řádky se nemění)")
        } else {
            report.steps.append("Blok v \(paths.zshrc.path) už existuje beze změny")
        }
        report.changed = !helperCurrent || !snippetCurrent || zshrcChanged
        if dryRun || !report.changed { return report }

        do {
            if !helperCurrent { try AtomicFile.write(helperBytes, to: paths.helper, mode: 0o755) }
            if !snippetCurrent { try AtomicFile.write(Data(snippet.utf8), to: paths.snippet, mode: 0o600) }
            guard zshrcChanged else { return report }
            if let original { report.backup = try backUp(original) }
            try writeZshrc(updated, mode: mode, expectedOriginal: original)
            try verify(originalWithoutBlock: try Self.removing(from: original ?? ""), expectBlock: true, restore: original)
        } catch let error as ClaudeHookError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
        return report
    }

    /// `removeHelper: false` keeps the shared helper because another integration still uses it.
    @discardableResult
    public func uninstall(dryRun: Bool = false, removeHelper: Bool = true) throws(ClaudeHookError) -> ClaudeHookReport {
        var report = ClaudeHookReport()
        if let info = try lstatZshrc(), (info.st_mode & S_IFMT) == S_IFLNK { throw .settingsIsSymlink(paths.zshrc.path) }

        var original: String?
        var mode: mode_t = 0o644
        if let info = try lstatZshrc() {
            do { original = try String(contentsOf: paths.zshrc, encoding: .utf8) } catch { throw .io(error.localizedDescription) }
            mode = info.st_mode & 0o777
        }
        var hadBlock = false
        if let original { hadBlock = try Self.hasBlock(original) }
        let snippetPresent = FileManager.default.fileExists(atPath: paths.snippet.path)
        let helperPresent = removeHelper && FileManager.default.fileExists(atPath: paths.helper.path)

        if hadBlock {
            report.steps.append("Zálohuje \(paths.zshrc.path) do \(paths.backups.path)")
            report.steps.append("Odebere z \(paths.zshrc.path) pouze blok Pure Clipboard")
        }
        if snippetPresent { report.steps.append("Smaže \(paths.snippet.path)") }
        if helperPresent { report.steps.append("Smaže pomocný program \(paths.helper.path)") }
        report.changed = hadBlock || snippetPresent || helperPresent
        if dryRun || !report.changed { return report }

        do {
            if hadBlock, let original {
                report.backup = try backUp(original)
                let updated = try Self.removing(from: original)
                try writeZshrc(updated, mode: mode, expectedOriginal: original)
                try verify(originalWithoutBlock: updated, expectBlock: false, restore: original)
            }
            if snippetPresent { try FileManager.default.removeItem(at: paths.snippet) }
            if helperPresent { try FileManager.default.removeItem(at: paths.helper) }
        } catch let error as ClaudeHookError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
        return report
    }

    // MARK: Helpers

    private func writeZshrc(_ text: String, mode: mode_t, expectedOriginal: String?) throws(ClaudeHookError) {
        let latest = try? String(contentsOf: paths.zshrc, encoding: .utf8)
        guard latest == expectedOriginal else { throw .modifiedExternally }
        do {
            try AtomicFile.write(Data(text.utf8), to: paths.zshrc, mode: mode)
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    private func backUp(_ original: String) throws(ClaudeHookError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let data = Data(original.utf8)
        let url = paths.backups.appendingPathComponent("zshrc-\(formatter.string(from: Date()))-\(ConfigFileStore.fingerprint(data).prefix(8))")
        do { try AtomicFile.write(data, to: url, mode: 0o600) } catch { throw .io(error.localizedDescription) }
        return url
    }

    private func verify(originalWithoutBlock: String, expectBlock: Bool, restore original: String?) throws(ClaudeHookError) {
        func rollback(_ reason: String) -> ClaudeHookError {
            if let original { try? AtomicFile.write(Data(original.utf8), to: paths.zshrc, mode: 0o644) }
            else { try? FileManager.default.removeItem(at: paths.zshrc) }
            return .verificationFailed(reason)
        }
        let written: String
        do { written = try String(contentsOf: paths.zshrc, encoding: .utf8) } catch { throw rollback(error.localizedDescription) }
        let present: Bool
        do { present = try Self.hasBlock(written) } catch { throw rollback("blok není v pořádku") }
        guard present == expectBlock else { throw rollback("blok \(expectBlock ? "chybí" : "zůstal")") }
        let rest = (try? Self.removing(from: written)) ?? written
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed(rest) == trimmed(originalWithoutBlock) else { throw rollback("změnil se jiný obsah než blok") }
    }
}
