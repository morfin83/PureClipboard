import Darwin
import Foundation

/// Serialises clipboard writes of all agents (Claude Code, Codex, ...) and remembers who wrote last,
/// so that several agents finishing at nearly the same moment cannot overwrite each other.
public struct ClipboardClaimStore: Sendable {
    public struct Claim: Codable, Equatable, Sendable {
        public var source: String
        public var session: String
        public var time: Date

        public init(source: String, session: String, time: Date) {
            self.source = source
            self.session = session
            self.time = time
        }
    }

    /// A different session that copied less than this long ago keeps the clipboard.
    public static let defaultWindow: TimeInterval = 5
    public static let lockTimeout: TimeInterval = 2

    public let directory: URL
    public let window: TimeInterval

    public init(directory: URL, window: TimeInterval = ClipboardClaimStore.defaultWindow) {
        self.directory = directory
        self.window = window
    }

    var lockURL: URL { directory.appendingPathComponent("clipboard.lock") }
    var claimURL: URL { directory.appendingPathComponent("clipboard-claim.json") }

    /// Runs `body` while holding an exclusive cross-process lock. Returns nil if the lock cannot be taken in time.
    public func withLock<T>(_ body: () -> T) -> T? {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(Self.lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return nil }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// Must be called while holding the lock. An unreadable claim file counts as "no claim".
    public func lastClaim() -> Claim? {
        guard let data = try? Data(contentsOf: claimURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Claim.self, from: data)
    }

    public func record(_ claim: Claim) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(claim) else { return }
        try? AtomicFile.write(data, to: claimURL, mode: 0o600)
    }

    /// True when `candidate` should not overwrite the clipboard because another session just did.
    public func isBlocked(by last: Claim?, candidate: Claim) -> Bool {
        guard let last else { return false }
        if last.source == candidate.source && last.session == candidate.session { return false }
        let age = candidate.time.timeIntervalSince(last.time)
        return age >= 0 && age < window
    }
}
