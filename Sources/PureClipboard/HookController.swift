import Foundation
import Observation
import PureClipboardCore

/// State and actions for one agent integration (Claude Code or Codex) on the main actor.
@MainActor
@Observable
final class HookController {
    let target: HookTarget
    private let store: ConfigFileStore

    private(set) var state = ClaudeHookState()
    private(set) var event: HookEventRecord?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var testResult: String?

    init(target: HookTarget, store: ConfigFileStore) {
        self.target = target
        self.store = store
        refresh()
    }

    private func installer(for target: HookTarget) -> ClaudeHookInstaller {
        ClaudeHookInstaller(paths: .standard(target: target, configURL: store.url), target: target)
    }

    private var installer: ClaudeHookInstaller { installer(for: target) }

    /// The helper shipped inside this app bundle; nil when running outside a bundle.
    var bundledHelper: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(ClaudeHookInstaller.helperName)
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    var settingsPath: String { (installer.paths.settings.path as NSString).abbreviatingWithTildeInPath }

    func refresh() {
        state = installer.state(bundledHelper: bundledHelper)
        event = HookEventRecord.read(besides: store.url, integration: target.integration)
    }

    /// Human-readable list of exactly what installing would change. Writes nothing.
    func installPlan() -> [String] {
        guard let helper = bundledHelper else { return ["Pomocný program hooku v aplikaci nebyl nalezen."] }
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
                ? "Hook nainstalován." + (report.backup.map { " Záloha: \($0.lastPathComponent)" } ?? "")
                : "Hook už byl nainstalován, není co měnit."
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func remove() {
        error = nil
        notice = nil
        let other: HookTarget = target == .claude ? .codex : .claude
        let terminal = ZshIntegrationInstaller(paths: .standard(configURL: store.url)).state().isInstalled
        let termux = TermuxChannelInstaller(supportDirectory: store.url.deletingLastPathComponent()).state().isInstalled
        let helperStillNeeded = installer(for: other).state().isRegistered || terminal || termux
        do {
            let report = try installer.uninstall(removeHelper: !helperStillNeeded)
            notice = report.changed
                ? "Hook odebrán." + (report.backup.map { " Záloha: \($0.lastPathComponent)" } ?? "")
                : "Hook nebyl nainstalován."
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    /// Runs the real decision logic on a harmless sample. With `writeToClipboard` the sample really replaces the clipboard.
    func runTest(writeToClipboard: Bool) {
        let clipboard: ClipboardWriting = writeToClipboard ? SystemClipboard() : DiscardingClipboard()
        let outcome = HookSelfTest.run(store: store, integration: target.integration, clipboard: clipboard)
        var text: String
        switch outcome.result {
        case .copied:
            text = writeToClipboard
                ? "Test v pořádku: ukázkový text byl zkopírován do schránky."
                : "Test v pořádku: ukázkový text by se zkopíroval (schránka zůstala beze změny)."
        case .skipped:
            text = "Test: nic by se nezkopírovalo – \(HookReasonLabel.text(outcome.reason))."
        }
        if !state.isRegistered { text += " Hook ještě není nainstalován, takže sám od sebe nic nezkopíruje." }
        testResult = text
    }
}
