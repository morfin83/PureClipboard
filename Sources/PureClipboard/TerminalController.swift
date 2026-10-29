import Foundation
import Observation
import PureClipboardCore

/// State and actions for the opt-in Terminal integration (the `pclip` zsh function).
@MainActor
@Observable
final class TerminalController {
    private let store: ConfigFileStore

    private(set) var state = ZshIntegrationState()
    private(set) var event: HookEventRecord?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var testResult: String?

    init(store: ConfigFileStore) {
        self.store = store
        refresh()
    }

    private var installer: ZshIntegrationInstaller {
        ZshIntegrationInstaller(paths: .standard(configURL: store.url))
    }

    var bundledHelper: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(ClaudeHookInstaller.helperName)
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    var zshrcPath: String { (installer.paths.zshrc.path as NSString).abbreviatingWithTildeInPath }

    func refresh() {
        state = installer.state(bundledHelper: bundledHelper)
        event = HookEventRecord.read(besides: store.url, integration: .terminal)
    }

    func installPlan() -> [String] {
        guard let helper = bundledHelper else { return ["Pomocný program v aplikaci nebyl nalezen."] }
        do {
            return try installer.install(bundledHelper: helper, dryRun: true).steps
        } catch {
            return [error.localizedDescription]
        }
    }

    func install() {
        error = nil
        notice = nil
        guard let helper = bundledHelper else {
            error = ClaudeHookError.helperMissing("Contents/MacOS/\(ClaudeHookInstaller.helperName)").localizedDescription
            return
        }
        do {
            let report = try installer.install(bundledHelper: helper)
            notice = report.changed
                ? "Integrace nainstalována. Otevřete nové okno Terminálu a zkuste: pclip echo test." + (report.backup.map { " Záloha: \($0.lastPathComponent)" } ?? "")
                : "Integrace už byla nainstalována, není co měnit."
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func remove() {
        error = nil
        notice = nil
        let others = [HookTarget.claude, .codex].contains {
            ClaudeHookInstaller(paths: .standard(target: $0, configURL: store.url), target: $0).state().isRegistered
        }
        do {
            let report = try installer.uninstall(removeHelper: !others)
            notice = report.changed
                ? "Integrace odebrána." + (report.backup.map { " Záloha: \($0.lastPathComponent)" } ?? "")
                : "Integrace nebyla nainstalována."
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func runTest(writeToClipboard: Bool) {
        let clipboard: ClipboardWriting = writeToClipboard ? SystemClipboard() : DiscardingClipboard()
        let outcome = TerminalCopyHandler.selfTest(store: store, clipboard: clipboard)
        var text: String
        switch outcome.result {
        case .copied:
            text = writeToClipboard
                ? "Test v pořádku: ukázkový výstup byl zkopírován do schránky."
                : "Test v pořádku: ukázkový výstup by se zkopíroval (schránka zůstala beze změny)."
        case .skipped:
            text = "Test: nic by se nezkopírovalo – \(HookReasonLabel.text(outcome.reason))."
        }
        if !state.isInstalled { text += " Příkaz pclip ještě není nainstalován." }
        testResult = text
    }
}
