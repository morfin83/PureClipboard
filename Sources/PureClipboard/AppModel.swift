import Foundation
import Observation
import PureClipboardCore

@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case missing
        case failed(ConfigError)
    }

    let store: ConfigFileStore
    private(set) var state: LoadState = .loading
    private(set) var config: PureClipboardConfig?
    private(set) var permissions: UInt16?
    private(set) var lastLoaded: Date?
    private(set) var lastSaved: Date?
    private(set) var saveError: ConfigError?

    let claude: HookController
    let codex: HookController
    let terminal: TerminalController
    let remote = RemoteController()

    private var document: ConfigDocument?
    private var fingerprint: String?

    init(store: ConfigFileStore) {
        self.store = store
        claude = HookController(target: .claude, store: store)
        codex = HookController(target: .codex, store: store)
        terminal = TerminalController(store: store)
        reload()
    }

    func controller(for target: HookTarget) -> HookController { target == .claude ? claude : codex }

    func refreshHooks() {
        claude.refresh()
        codex.refresh()
        terminal.refresh()
    }

    var configPath: String {
        (store.url.path as NSString).abbreviatingWithTildeInPath
    }

    var isEditable: Bool { state == .loaded && config != nil }

    func reload() {
        saveError = nil
        refreshHooks()
        do {
            let loaded = try store.load()
            apply(loaded)
            lastLoaded = Date()
            state = .loaded
        } catch .fileNotFound {
            clear()
            state = .missing
        } catch {
            // Keep nothing editable: a broken file must never be overwritten by defaults.
            clear()
            state = .failed(error)
        }
    }

    /// Only offered when no file exists; never replaces an existing one.
    func createDefaultConfig() {
        guard state == .missing else { return }
        do {
            let saved = try store.save(ConfigDocument(config: .defaults), expectedFingerprint: nil)
            apply(saved)
            lastSaved = Date()
            state = .loaded
        } catch {
            saveError = error
        }
    }

    func update(_ mutate: (inout PureClipboardConfig) -> Void) {
        guard isEditable, var next = document else { return }
        mutate(&next.config)
        guard next.config != document?.config else { return }
        do {
            let saved = try store.save(next, expectedFingerprint: fingerprint)
            apply(saved)
            lastSaved = Date()
            saveError = nil
        } catch {
            // The UI reverts to the last persisted values.
            saveError = error
        }
    }

    private func apply(_ loaded: LoadedConfig) {
        document = loaded.document
        config = loaded.document.config
        fingerprint = loaded.fingerprint
        permissions = loaded.permissions
    }

    private func clear() {
        document = nil
        config = nil
        fingerprint = nil
        permissions = nil
    }
}
