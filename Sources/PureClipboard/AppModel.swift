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

    private(set) var hookState = ClaudeHookState()
    private(set) var hookEvent: HookEventRecord?
    private(set) var hookError: String?
    private(set) var hookNotice: String?

    private var document: ConfigDocument?
    private var fingerprint: String?

    init(store: ConfigFileStore) {
        self.store = store
        reload()
    }

    // MARK: Claude Code hook

    private var installer: ClaudeHookInstaller {
        ClaudeHookInstaller(paths: .standard(configURL: store.url))
    }

    /// The helper shipped inside this app bundle; nil when running outside a bundle.
    var bundledHelper: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(ClaudeHookInstaller.helperName)
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    var settingsPath: String { (installer.paths.settings.path as NSString).abbreviatingWithTildeInPath }

    func refreshHook() {
        hookState = installer.state(bundledHelper: bundledHelper)
        hookEvent = HookEventRecord.read(besides: store.url)
    }

    /// Human-readable list of exactly what installing would change. Writes nothing.
    func hookInstallPlan() -> [String] {
        guard let helper = bundledHelper else { return ["Pomocný program hooku v aplikaci nebyl nalezen."] }
        do {
            return try installer.install(bundledHelper: helper, dryRun: true).steps
        } catch {
            return [error.localizedDescription]
        }
    }

    func installHook() {
        hookError = nil
        hookNotice = nil
        guard let helper = bundledHelper else {
            hookError = ClaudeHookError.helperMissing("Contents/MacOS/\(ClaudeHookInstaller.helperName)").localizedDescription
            return
        }
        do {
            let report = try installer.install(bundledHelper: helper)
            hookNotice = report.changed
                ? "Hook nainstalován." + (report.backup.map { " Záloha: \($0.lastPathComponent)" } ?? "")
                : "Hook už byl nainstalován, není co měnit."
        } catch {
            hookError = error.localizedDescription
        }
        refreshHook()
    }

    func removeHook() {
        hookError = nil
        hookNotice = nil
        do {
            let report = try installer.uninstall()
            hookNotice = report.changed
                ? "Hook odebrán." + (report.backup.map { " Záloha: \($0.lastPathComponent)" } ?? "")
                : "Hook nebyl nainstalován."
        } catch {
            hookError = error.localizedDescription
        }
        refreshHook()
    }

    var configPath: String {
        (store.url.path as NSString).abbreviatingWithTildeInPath
    }

    var isEditable: Bool { state == .loaded && config != nil }

    func reload() {
        saveError = nil
        refreshHook()
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
