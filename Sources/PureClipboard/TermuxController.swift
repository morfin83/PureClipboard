import AppKit
import Foundation
import Observation
import PureClipboardCore

/// State and actions for the Termux channel (S25 ↔ Mac). Nothing here runs a process or opens a connection:
/// the phone connects with its own SSH key and calls the helper; this controller only manages the Mac-side mailboxes.
@MainActor
@Observable
final class TermuxController {
    private let store: ConfigFileStore

    private(set) var state = TermuxChannelState()
    private(set) var inbox: [TermuxItem] = []
    private(set) var outbox: [TermuxItem] = []
    private(set) var event: HookEventRecord?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var testResult: String?

    init(store: ConfigFileStore) {
        self.store = store
        refresh()
    }

    private var support: URL { store.url.deletingLastPathComponent() }
    private var installer: TermuxChannelInstaller { TermuxChannelInstaller(supportDirectory: support) }
    private var handler: TermuxChannelHandler { TermuxChannelHandler(store: store, mailbox: installer.mailbox) }

    var bundledHelper: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(ClaudeHookInstaller.helperName)
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    var helperPath: String { installer.helper.path }

    /// Command that the user types or pastes in Termux once to download the `pcr` script from this Mac.
    func bootstrapCommand(host: String) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = cleanHost.isEmpty ? "ADRESA_MACU" : cleanHost
        let quoted = "'" + installer.helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let remote = "\"" + quoted.replacingOccurrences(of: "\"", with: "\\\"") + " termux-script --host \(target)\""
        return "ssh \(NSUserName())@\(target) \(remote) > ~/pcr && chmod +x ~/pcr"
    }

    func refresh() {
        state = installer.state()
        inbox = state.mailboxReady ? installer.mailbox.list(.inbox) : []
        outbox = state.mailboxReady ? installer.mailbox.list(.outbox) : []
        event = HookEventRecord.read(besides: store.url, integration: .termux)
    }

    func installPlan() -> [String] {
        guard let helper = bundledHelper else { return ["Pomocný program v aplikaci nebyl nalezen."] }
        do { return try installer.install(bundledHelper: helper, dryRun: true).steps } catch { return [error.localizedDescription] }
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
            notice = report.changed ? "Kanál připraven. Zbývá jednorázově nainstalovat skript pcr v Termuxu." : "Kanál už byl připraven, není co měnit."
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
        } || ZshIntegrationInstaller(paths: .standard(configURL: store.url)).state().isInstalled
        do {
            let report = try installer.uninstall(removeHelper: !others)
            notice = report.changed ? "Kanál odebrán, čekající texty smazány." : "Kanál nebyl nainstalován."
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    // MARK: Explicit actions on texts

    /// Reads the Mac clipboard ONCE, because the user pressed the button, and queues the text for the phone.
    func sendClipboardToPhone() {
        error = nil
        notice = nil
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            error = "Ve schránce Macu není žádný text."
            return
        }
        report(handler.send(Data(text.utf8), to: "s25"), success: "Text čeká na vyzvednutí v Termuxu příkazem pcr frommac.")
    }

    func copyToClipboard(_ item: TermuxItem) {
        error = nil
        notice = nil
        let outcome = handler.copyToClipboard(
            item, clipboard: SystemClipboard(), claims: ClipboardClaimStore(directory: support))
        report(outcome, success: "Text je ve schránce Macu.")
    }

    func discard(_ item: TermuxItem, from box: TermuxBox) {
        installer.mailbox.remove(id: item.id, from: box)
        refresh()
    }

    func clear(_ box: TermuxBox) {
        installer.mailbox.removeAll(box)
        refresh()
    }

    /// Dry run in a throw-away mailbox: shows whether text from the phone would be accepted. Writes nothing to the real mailboxes.
    func runTest() {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pc-termux-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let probe = TermuxChannelHandler(store: store, mailbox: TermuxMailbox(supportDirectory: scratch))
        let outcome = probe.receive(Data("Pure Clipboard – zkušební text z telefonu (neškodný).".utf8), from: "s25")
        var text = outcome.result == .copied
            ? "Test v pořádku: text z S25 by se přijal do přijaté pošty (nic se neuložilo)."
            : "Test: text by se nepřijal – \(HookReasonLabel.text(outcome.reason))."
        if !state.isInstalled { text += " Kanál ještě není nainstalován." }
        testResult = text
    }

    /// Puts one harmless sample into the real inbox so the whole flow (inbox → copy button) can be tried without the phone.
    func addSampleToInbox() {
        error = nil
        notice = nil
        report(handler.receive(Data("Pure Clipboard – zkušební položka (neškodný text).".utf8), from: "s25"),
               success: "Zkušební položka je v přijaté poště.")
    }

    private func report(_ outcome: HookOutcome, success: String) {
        switch outcome.result {
        case .copied: notice = success
        case .skipped: error = "Nepodařilo se – \(HookReasonLabel.text(outcome.reason))."
        }
        HookEventRecord.write(outcome, besides: store.url, integration: .termux)
        refresh()
    }
}
