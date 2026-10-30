import Foundation

/// How the Mac reaches the phone. Decides chunk size and whether mobile data may be spent.
public enum TransferLink: String, Codable, Sendable {
    case usb, wifi, mobile, unknown

    /// Larger chunks amortise the per-chunk `adb` round trips on fast links; small ones keep progress honest on slow links.
    public var chunkSize: Int64 {
        switch self {
        case .usb: 64 * 1_048_576
        case .wifi: 16 * 1_048_576
        case .unknown: 8 * 1_048_576
        case .mobile: 4 * 1_048_576
        }
    }
}

public enum TransferState: String, Codable, Sendable {
    case queued, preparing, running, pausing, paused, verifying, completed, failed, canceled

    public var isFinished: Bool { self == .completed || self == .failed || self == .canceled }
    public var isActive: Bool { [.preparing, .running, .pausing, .verifying].contains(self) }
}

public enum TransferPauseReason: String, Codable, Sendable {
    case user
    /// The phone is reachable only over mobile data; the user has to confirm spending it.
    case mobileData
    case connectionLost
    case noPhone
    /// The app was closed or crashed while the job was active.
    case interrupted
}

public struct TransferJob: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sourcePath: String
    public var sourceName: String
    public var size: Int64
    public var modifiedAt: Double
    public var sha256: String?
    public var destinationDirectory: String
    public var destinationName: String?
    /// Bytes confirmed on the phone (the size of the partial file there).
    public var bytesDone: Int64
    public var state: TransferState
    public var pauseReason: TransferPauseReason?
    public var message: String?
    public var link: TransferLink?
    public var allowMobileData: Bool
    public var createdAt: Double
    public var startedAt: Double?
    public var finishedAt: Double?
    public var averageBytesPerSecond: Double?

    public init(
        id: String = UUID().uuidString, sourcePath: String, sourceName: String, size: Int64, modifiedAt: Double,
        destinationDirectory: String, createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceName = sourceName
        self.size = size
        self.modifiedAt = modifiedAt
        self.destinationDirectory = destinationDirectory
        self.bytesDone = 0
        self.state = .queued
        self.allowMobileData = false
        self.createdAt = createdAt
    }

    public var fraction: Double {
        size > 0 ? min(1, Double(bytesDone) / Double(size)) : (state == .completed ? 1 : 0)
    }
}

/// Persisted preferences of the transfer feature (kept apart from config.json on purpose).
public struct TransferSettings: Codable, Sendable, Equatable {
    /// `host:port` of the phone for wireless ADB (e.g. its Tailscale address); nil = USB only.
    public var endpoint: String?
    public var destinationDirectory: String

    public static let defaultDestination = "/sdcard/Download"

    public init(endpoint: String? = nil, destinationDirectory: String = TransferSettings.defaultDestination) {
        self.endpoint = endpoint
        self.destinationDirectory = destinationDirectory
    }

    /// Accepts `host`, `host:port` or `[v6]:port`; rejects anything that could be mistaken for an option or contain a shell metacharacter.
    public static func normalizedEndpoint(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !value.hasPrefix("-") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]_")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let hasPort = value.contains("]:") || (!value.contains("[") && value.filter { $0 == ":" }.count == 1)
        return hasPort ? value : value + ":5555"
    }

    public static func isValidDestination(_ path: String) -> Bool {
        guard path.hasPrefix("/sdcard/"), !path.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        return path.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public enum TransferError: Error, LocalizedError, Sendable, Equatable {
    case adbMissing
    case noPhone(String)
    case commandFailed(String)
    case timedOut
    case invalidSource(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case destinationBusy

    public var errorDescription: String? {
        switch self {
        case .adbMissing:
            "Nástroj adb nebyl nalezen. Nainstalujte ho (brew install android-platform-tools)."
        case .noPhone(let detail):
            detail
        case .commandFailed(let detail):
            "Příkaz na telefonu selhal: \(detail)"
        case .timedOut:
            "Telefon neodpověděl včas."
        case .invalidSource(let detail):
            detail
        case .notEnoughSpace(let needed, let available):
            "Na telefonu není dost místa (potřeba \(needed / 1_048_576) MB, volno \(max(0, available) / 1_048_576) MB)."
        case .sizeMismatch(let expected, let actual):
            "Velikost na telefonu nesouhlasí (čekáno \(expected) B, je \(actual) B)."
        case .checksumMismatch:
            "Kontrolní součet na telefonu nesouhlasí se zdrojovým souborem. Přenos je potřeba zopakovat."
        case .destinationBusy:
            "Cílový soubor na telefonu se nepodařilo vytvořit."
        }
    }
}

/// Moving-window throughput. Fed with cumulative confirmed bytes each time a chunk lands on the phone.
public struct TransferSpeedMeter: Sendable {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 8) {
        self.window = window
    }

    public mutating func reset(at time: TimeInterval, bytes: Int64) {
        samples = [(time, bytes)]
    }

    public mutating func add(bytes: Int64, at time: TimeInterval) {
        samples.append((time, bytes))
        while samples.count > 2, let first = samples.first, time - first.time > window {
            samples.removeFirst()
        }
    }

    public var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time, last.bytes >= first.bytes else { return 0 }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    public static func eta(remaining: Int64, bytesPerSecond: Double) -> TimeInterval? {
        guard bytesPerSecond > 1, remaining >= 0 else { return nil }
        return Double(remaining) / bytesPerSecond
    }
}

/// Picks a file name that does not exist yet: `name.ext`, `name (2).ext`, …
public enum TransferNaming {
    public static func sanitized(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            (scalar.value < 32 || scalar == "/" || scalar.value == 127) ? "_" : Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { cleaned = "soubor" }
        // Android file names are limited to 255 bytes; keep the extension when shortening.
        while cleaned.utf8.count > 240 {
            let url = URL(fileURLWithPath: cleaned)
            let ext = url.pathExtension
            var base = String(url.deletingPathExtension().lastPathComponent.dropLast())
            if base.isEmpty { base = "soubor" }
            cleaned = ext.isEmpty ? base : base + "." + ext
        }
        return cleaned
    }

    public static func candidate(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
    }
}
