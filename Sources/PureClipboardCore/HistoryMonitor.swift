import AppKit
import Foundation

/// Thread-safe holder so the monitor always sees the latest settings without touching the UI model.
public final class HistorySettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ClipboardHistorySettings

    public init(_ value: ClipboardHistorySettings = .defaults) { self.value = value }

    public var current: ClipboardHistorySettings {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Counters and last reasons only — never any clipboard content.
public struct HistoryMonitorStatus: Equatable, Sendable {
    public var running = false
    public var storedCount = 0
    public var skippedCount = 0
    public var lastSkipReason: String?
    public var lastStoredAt: Date?

    public init() {}
}

/// Polls `NSPasteboard.changeCount` (macOS has no change notification) while the history is switched on and not paused.
/// Whatever is on the pasteboard when it starts is not captured: history only records copies made afterwards.
public final class ClipboardHistoryMonitor: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let capture: HistoryCapture
    private let settings: HistorySettingsBox
    private let sourceApp: @Sendable () -> String?
    private let onChange: @Sendable (HistoryMonitorStatus) -> Void
    private let queue = DispatchQueue(label: "studio.pure.clipboard.history", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var ignored: Set<Int> = []
    private var status = HistoryMonitorStatus()

    public init(
        pasteboard: NSPasteboard = .general, capture: HistoryCapture, settings: HistorySettingsBox,
        sourceApp: @escaping @Sendable () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName },
        onChange: @escaping @Sendable (HistoryMonitorStatus) -> Void = { _ in }
    ) {
        self.pasteboard = pasteboard
        self.capture = capture
        self.settings = settings
        self.sourceApp = sourceApp
        self.onChange = onChange
        self.lastChangeCount = pasteboard.changeCount
    }

    public var currentStatus: HistoryMonitorStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// Starts or stops polling to match the current settings. Safe to call at any time.
    public func settingsChanged() {
        let capturing = settings.current.isCapturing
        lock.lock()
        let isRunning = timer != nil
        lock.unlock()
        if capturing && !isRunning { start() } else if !capturing && isRunning { stop() }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        // Start from "now": content copied before the user turned history on is not stored.
        lastChangeCount = pasteboard.changeCount
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        status.running = true
        source.resume()
        let snapshot = status
        DispatchQueue.global().async { [onChange] in onChange(snapshot) }
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        status.running = false
        let snapshot = status
        lock.unlock()
        onChange(snapshot)
    }

    /// The restore action writes to the pasteboard itself; that write must not become a new history item.
    public func ignore(changeCount: Int) {
        lock.lock()
        ignored.insert(changeCount)
        lock.unlock()
    }

    /// One polling step. Internal so tests can drive it without waiting for the timer.
    func poll() {
        let count = pasteboard.changeCount
        lock.lock()
        guard count != lastChangeCount else { lock.unlock(); return }
        lastChangeCount = count
        let skipOwn = ignored.remove(count) != nil
        lock.unlock()
        if skipOwn { return }

        let current = settings.current
        guard current.isCapturing else { return }
        let snapshot = PasteboardReader.snapshot(of: pasteboard, sourceApp: sourceApp())
        // The pasteboard may have changed while it was being read; the next poll will pick the newer content up.
        guard snapshot.changeCount == count else { return }

        let outcome = capture.process(snapshot, settings: current)
        lock.lock()
        switch outcome {
        case .stored:
            status.storedCount += 1
            status.lastStoredAt = Date()
        case .skipped(let reason):
            status.skippedCount += 1
            status.lastSkipReason = reason
        }
        let updated = status
        lock.unlock()
        onChange(updated)
    }
}
