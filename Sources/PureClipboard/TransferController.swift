import AppKit
import Foundation
import Observation
import PureClipboardCore

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
    private(set) var settings: TransferSettings
    private(set) var adbPath: String?
    private(set) var notice: String?
    var endpointText: String

    private let store: TransferStore
    private let engine: TransferEngine
    private var pollTask: Task<Void, Never>?

    var activeCount: Int { jobs.filter { $0.state.isActive || $0.state == .queued }.count }

    init(supportDirectory: URL, monitoring: Bool) {
        let store = TransferStore(supportDirectory: supportDirectory)
        self.store = store
        let settings = store.loadSettings()
        self.settings = settings
        endpointText = settings.endpoint ?? ""
        let adb = AdbLocator.find()
        adbPath = adb
        let resolver: any PhoneResolving = adb.map { AdbPhoneResolver(adb: $0) } ?? MissingAdbResolver()
        engine = TransferEngine(store: store, resolver: resolver, settings: settings)
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
                self?.jobs = jobs
                self?.speeds = speeds
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pickUpRequests()
                try? await Task.sleep(for: .seconds(1))
            }
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
            Task { await engine.updateSettings(new) }
        } catch {
            notice = "Nastavení se nepodařilo uložit: \(error.localizedDescription)"
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

    func pause(_ job: TransferJob) { Task { await engine.pause(job.id) } }
    func resume(_ job: TransferJob) { Task { await engine.resume(job.id) } }
    func resumeOnMobileData(_ job: TransferJob) { Task { await engine.resume(job.id, allowMobileData: true) } }
    func cancel(_ job: TransferJob) { Task { await engine.cancel(job.id) } }
    func remove(_ job: TransferJob) { Task { await engine.remove(job.id) } }
    func clearFinished() { Task { await engine.clearFinished() } }

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
