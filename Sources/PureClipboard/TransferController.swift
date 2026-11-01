import AppKit
import Foundation
import Observation
import PureClipboardCore
@preconcurrency import UserNotifications

/// A resolver used when `adb` is not installed: every job pauses with an explanation instead of failing silently.
private struct MissingAdbResolver: PhoneResolving {
    func resolve(settings: TransferSettings) async throws -> PhoneTarget { throw TransferError.adbMissing }
}

/// UI state for sending files to the phone. All real work happens in `TransferEngine`; this class mirrors its jobs,
/// feeds it files (drag & drop, file picker, the helper's request folder) and forwards the buttons.
@MainActor
@Observable
final class TransferController {
    private(set) var jobs: [TransferJob] = []
    private(set) var speeds: [String: Double] = [:]
    /// Phone → Mac downloads; they have their own engine and are shown in their own section.
    private(set) var pullJobs: [TransferJob] = []
    /// The Downloads folder of the phone, as last listed by the user (never loaded automatically).
    private(set) var phoneFiles: [PhoneFileEntry] = []
    private(set) var phoneListLoaded = false
    private(set) var phoneListMessage: String?
    private(set) var settings: TransferSettings
    private(set) var adbPath: String?
    private(set) var notice: String?
    var endpointText: String

    private let store: TransferStore
    private let resolver: any PhoneResolving
    private let engine: TransferEngine
    private let pullEngine: PullEngine
    private var pollTask: Task<Void, Never>?

    var activeCount: Int { (jobs + pullJobs).filter { $0.state.isActive || $0.state == .queued }.count }

    init(supportDirectory: URL, monitoring: Bool) {
        let store = TransferStore(supportDirectory: supportDirectory)
        self.store = store
        let settings = store.loadSettings()
        self.settings = settings
        endpointText = settings.endpoint ?? ""
        let adb = AdbLocator.find()
        adbPath = adb
        let resolver: any PhoneResolving = adb.map { AdbPhoneResolver(adb: $0) } ?? MissingAdbResolver()
        self.resolver = resolver
        engine = TransferEngine(store: store, resolver: resolver, settings: settings)
        pullEngine = PullEngine(store: store, resolver: resolver, settings: settings)
        if monitoring {
            Task { await self.start() }
        } else {
            jobs = TransferController.sampleJobs()
            speeds = [jobs[0].id: 6_800_000]
        }
    }

    private func start() async {
        await engine.setObserver { [weak self] jobs, speeds in
            Task { @MainActor in
                self?.notifyChanges(from: self?.jobs ?? [], to: jobs)
                self?.jobs = jobs
                self?.speeds = speeds
            }
        }
        // Pulls: no system notifications yet, the card shows their state.
        await pullEngine.setObserver { [weak self] jobs, _ in
            Task { @MainActor in self?.pullJobs = jobs }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pickUpRequests()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Notifies only about state changes that need the user (finished, failed, waiting for mobile data or a phone).
    private func notifyChanges(from old: [TransferJob], to new: [TransferJob]) {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.state) })
        for job in new {
            // A job seen for the first time (e.g. restored at launch) is not news.
            guard let before = previous[job.id],
                  let message = TransferNotice.message(for: job, previous: before) else { continue }
            post(message, id: job.id)
        }
    }

    private func post(_ message: TransferNotice.Message, id: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            center.add(UNNotificationRequest(identifier: "transfer-\(id)-\(message.title)", content: content, trigger: nil))
        }
    }

    /// Files handed over by `pureclipboard-hook transfer-enqueue` (e.g. from the Finder quick action).
    private func pickUpRequests() async {
        let paths = store.drainRequests()
        guard !paths.isEmpty else { return }
        await add(paths: paths)
    }

    // MARK: Adding

    func add(urls: [URL]) {
        Task { await add(paths: urls.map(\.path)) }
    }

    private func add(paths: [String]) async {
        let result = await engine.enqueue(paths: paths)
        if result.rejected.isEmpty {
            notice = nil
        } else {
            let names = result.rejected.map { ($0 as NSString).lastPathComponent }.prefix(3).joined(separator: ", ")
            notice = "Přeskočeno (složka nebo nečitelný soubor): \(names)\(result.rejected.count > 3 ? "…" : "")"
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Poslat do telefonu"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    // MARK: Settings

    var endpointIsValid: Bool {
        endpointText.trimmingCharacters(in: .whitespaces).isEmpty || TransferSettings.normalizedEndpoint(endpointText) != nil
    }

    func saveEndpoint() {
        let text = endpointText.trimmingCharacters(in: .whitespaces)
        var new = settings
        if text.isEmpty {
            new.endpoint = nil
        } else if let normalized = TransferSettings.normalizedEndpoint(text) {
            new.endpoint = normalized
            endpointText = normalized
        } else {
            notice = "Adresa telefonu má tvar adresa:port, například 100.92.44.15:5555."
            return
        }
        do {
            try store.save(new)
            settings = new
            notice = nil
            Task {
                await engine.updateSettings(new)
                await pullEngine.updateSettings(new)
            }
            testConnection()
        } catch {
            notice = "Nastavení se nepodařilo uložit: \(error.localizedDescription)"
        }
    }

    /// Checks that the phone answers now. When it answers on another port (found on the local network), the new
    /// address and the phone's serial number are saved, so the next connection starts from the right place.
    func testConnection() {
        Task { await checkConnection() }
    }

    private func checkConnection() async {
        let current = settings
        do {
            let target = try await resolver.resolve(settings: current)
            var updated = current
            if let endpoint = target.endpoint, endpoint != current.endpoint {
                updated.endpoint = endpoint
            }
            if let serial = target.serial, serial != current.phoneSerial {
                updated.phoneSerial = serial
            }
            if updated != current {
                try store.save(updated)
                settings = updated
                endpointText = updated.endpoint ?? ""
                await engine.updateSettings(updated)
                await pullEngine.updateSettings(updated)
            }
            let via = target.link == .mobile ? " (mobilní data)" : ""
            notice = "Telefon odpovídá na \(target.endpoint ?? "kabelu USB")\(via)."
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// First online Android peer of the tailnet, as a hint for the address field.
    func suggestedEndpoint(from peers: [RemotePeerRate]) -> (name: String, endpoint: String)? {
        guard settings.endpoint == nil else { return nil }
        for item in peers where item.peer.online && item.peer.os.lowercased() == "android" {
            if let address = item.peer.addresses.first(where: { !$0.contains(":") }) {
                return (item.peer.name, "\(address):5555")
            }
        }
        return nil
    }

    func useSuggestion(_ endpoint: String) {
        endpointText = endpoint
        saveEndpoint()
    }

    // MARK: Actions

    func pause(_ job: TransferJob) {
        Task {
            if job.direction == .pull { await pullEngine.pause(job.id) } else { await engine.pause(job.id) }
        }
    }

    func resume(_ job: TransferJob) {
        Task {
            if job.direction == .pull { await pullEngine.resume(job.id) } else { await engine.resume(job.id) }
        }
    }

    func resumeOnMobileData(_ job: TransferJob) {
        Task {
            if job.direction == .pull {
                await pullEngine.resume(job.id, allowMobileData: true)
            } else {
                await engine.resume(job.id, allowMobileData: true)
            }
        }
    }

    func cancel(_ job: TransferJob) {
        Task {
            if job.direction == .pull { await pullEngine.cancel(job.id) } else { await engine.cancel(job.id) }
        }
    }

    func remove(_ job: TransferJob) {
        Task {
            if job.direction == .pull { await pullEngine.remove(job.id) } else { await engine.remove(job.id) }
        }
    }

    func clearFinished() {
        Task {
            await engine.clearFinished()
            await pullEngine.clearFinished()
        }
    }

    // MARK: Phone → Mac

    /// Lists the phone's Downloads folder. Called only from the button, never automatically.
    func loadPhoneFiles() {
        Task {
            do {
                let files = try await pullEngine.listDownloads()
                phoneFiles = files
                phoneListMessage = files.isEmpty ? "Složka Stažené v telefonu je prázdná." : nil
            } catch {
                phoneFiles = []
                phoneListMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            phoneListLoaded = true
        }
    }

    /// Starts one download; only a click on „Stáhnout“ reaches this.
    func download(_ file: PhoneFileEntry) {
        Task {
            let result = await pullEngine.enqueue([file])
            phoneListMessage = result.rejected.isEmpty ? nil : "Soubor \(file.name) nelze stáhnout (je mimo složku Stažené)."
        }
    }

    // MARK: Preview data for the rendered screenshots

    private static func sampleJobs() -> [TransferJob] {
        func make(_ name: String, size: Int64, done: Int64, state: TransferState, link: TransferLink) -> TransferJob {
            var job = TransferJob(
                sourcePath: "/Users/ukazka/\(name)", sourceName: name, size: size, modifiedAt: 0,
                destinationDirectory: TransferSettings.defaultDestination
            )
            job.bytesDone = done
            job.state = state
            job.link = link
            job.destinationName = name
            return job
        }
        var paused = make("Prezentace.pdf", size: 82_000_000, done: 31_000_000, state: .paused, link: .wifi)
        paused.pauseReason = .user
        var finished = make("pokus1_foto.jpeg", size: 20_700_000, done: 20_700_000, state: .completed, link: .wifi)
        finished.averageBytesPerSecond = 6_500_000
        return [
            make("Video z dovolene.mov", size: 412_000_000, done: 168_000_000, state: .running, link: .wifi),
            paused,
            finished,
        ]
    }
}
