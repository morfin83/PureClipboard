import AppKit
import Foundation
import Observation
import PureClipboardCore

@MainActor
@Observable
final class HistoryController {
    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private(set) var items: [HistoryItem] = []
    private(set) var status = HistoryMonitorStatus()
    private(set) var settings: ClipboardHistorySettings = .defaults
    private(set) var notice: Notice?
    var query = ""

    let store: HistoryStore
    private let box = HistorySettingsBox()
    private let claims: ClipboardClaimStore
    @ObservationIgnored private var monitor: ClipboardHistoryMonitor?

    init(configURL: URL, monitoring: Bool = true) {
        let directory = HistoryStore.defaultDirectory(configURL: configURL)
        store = HistoryStore(directory: directory)
        claims = ClipboardClaimStore(directory: configURL.deletingLastPathComponent())
        if monitoring {
            let capture = HistoryCapture(store: store, screener: VisionContentScreener())
            monitor = ClipboardHistoryMonitor(capture: capture, settings: box, onChange: { [weak self] status in
                Task { @MainActor in self?.monitorChanged(status) }
            })
        }
        refresh()
    }

    var filtered: [HistoryItem] { HistorySearch.filter(items, query: query) }
    var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    /// Called whenever the configuration is loaded or changed. A missing or broken config means history off.
    func apply(_ new: ClipboardHistorySettings?) {
        let next = new ?? .defaults
        let becameActive = next.isCapturing && !settings.isCapturing
        settings = next
        box.current = next
        monitor?.settingsChanged()
        if next.enabled {
            try? store.prune(settings: next)
        }
        if becameActive { notice = nil }
        refresh()
    }

    func refresh() {
        items = store.items()
        if let recovery = store.recoveryNotice {
            notice = Notice(text: recovery, isError: true)
            store.clearRecoveryNotice()
        }
    }

    private func monitorChanged(_ status: HistoryMonitorStatus) {
        self.status = status
        refresh()
    }

    func restore(_ item: HistoryItem) {
        let outcome = PasteboardRestorer.restore(item, from: store, to: .general, claims: claims)
        monitor?.ignore(changeCount: outcome.changeCount)
        switch outcome.result {
        case .restored: notice = Notice(text: "Položka je ve schránce.", isError: false)
        case .partial(let missing): notice = Notice(text: "Do schránky se dostalo vše kromě \(missing) chybějících originálů.", isError: true)
        case .failed(let message): notice = Notice(text: message, isError: true)
        }
    }

    func delete(_ item: HistoryItem) {
        do {
            try store.delete(id: item.id)
            notice = nil
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
        refresh()
    }

    func clearAll() {
        do {
            try store.clear()
            notice = Notice(text: "Celá historie byla smazána.", isError: false)
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
        refresh()
    }

    func dismissNotice() { notice = nil }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
}
