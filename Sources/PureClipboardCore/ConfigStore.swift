import CryptoKit
import Darwin
import Foundation

public enum ConfigError: Error, Equatable, LocalizedError, Sendable {
    case fileNotFound(String)
    case unreadable(String)
    case invalidJSON(String)
    case notAnObject
    case invalidStructure(String)
    case invalidValues([String])
    case symlinkRefused
    case modifiedExternally
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "Konfigurační soubor nebyl nalezen: \(path)."
        case .unreadable(let reason): "Soubor nelze přečíst: \(reason)."
        case .invalidJSON(let reason): "Soubor neobsahuje platný JSON: \(reason)."
        case .notAnObject: "Kořen konfigurace musí být JSON objekt."
        case .invalidStructure(let reason): "Neplatná struktura konfigurace: \(reason)."
        case .invalidValues(let issues): "Neplatné hodnoty: " + issues.joined(separator: " ")
        case .symlinkRefused: "Konfigurace je symbolický odkaz – z bezpečnostních důvodů se nepřepisuje."
        case .modifiedExternally: "Soubor byl mezitím změněn jinou aplikací. Načtěte jej znovu."
        case .writeFailed(let reason): "Uložení selhalo: \(reason)."
        }
    }
}

/// A parsed configuration together with the raw JSON it came from.
/// Saving overlays the typed values onto the raw tree, so unknown keys survive.
public struct ConfigDocument: Equatable, Sendable {
    public private(set) var raw: JSONValue
    public var config: PureClipboardConfig

    public init(data: Data) throws(ConfigError) {
        let raw: JSONValue
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .invalidJSON(Self.describe(error))
        }
        guard case .object = raw else { throw .notAnObject }

        let config: PureClipboardConfig
        do {
            config = try JSONDecoder().decode(PureClipboardConfig.self, from: data)
        } catch {
            throw .invalidStructure(Self.describe(error))
        }
        let issues = config.validationIssues()
        guard issues.isEmpty else { throw .invalidValues(issues) }

        self.raw = raw
        self.config = config
    }

    public init(config: PureClipboardConfig) {
        self.raw = .object([:])
        self.config = config
    }

    /// Validates and serializes the document. Throws instead of producing invalid output.
    public func encoded() throws(ConfigError) -> Data {
        let issues = config.validationIssues()
        guard issues.isEmpty else { throw .invalidValues(issues) }
        do {
            let typed = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(config))
            let merged = raw.merging(typed)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(merged)
            data.append(0x0A)
            // Re-parse what is about to be written so a broken file can never reach disk.
            _ = try ConfigDocument(data: data)
            return data
        } catch let error as ConfigError {
            throw error
        } catch {
            throw .writeFailed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            "chybí klíč „\(Self.path(context.codingPath + [key]))“"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "nesprávný typ u „\(Self.path(context.codingPath))“"
        case DecodingError.dataCorrupted(let context):
            context.codingPath.isEmpty ? "poškozená data" : "poškozená data u „\(Self.path(context.codingPath))“"
        default:
            error.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map(\.stringValue).joined(separator: ".")
    }
}

public struct LoadedConfig: Sendable {
    public var document: ConfigDocument
    /// SHA-256 of the bytes on disk, used to detect concurrent external edits.
    public var fingerprint: String
    public var permissions: UInt16
}

public struct ConfigFileStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PURECLIPBOARD_CONFIG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PureClipboard/config.json")
    }

    public func load() throws(ConfigError) -> LoadedConfig {
        guard let info = try lstatInfo() else { throw .fileNotFound(url.path) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        return LoadedConfig(
            document: try ConfigDocument(data: data),
            fingerprint: Self.fingerprint(data),
            permissions: UInt16(info.st_mode) & 0o777
        )
    }

    /// Atomically replaces the file with `document`, mode 0600.
    /// `expectedFingerprint` is the hash from the last load; nil means the file must not exist yet.
    @discardableResult
    public func save(_ document: ConfigDocument, expectedFingerprint: String?) throws(ConfigError) -> LoadedConfig {
        let data = try document.encoded()

        if let info = try lstatInfo() {
            if (info.st_mode & S_IFMT) == S_IFLNK { throw .symlinkRefused }
            let current: Data
            do { current = try Data(contentsOf: url) } catch { throw .unreadable(error.localizedDescription) }
            guard Self.fingerprint(current) == expectedFingerprint else { throw .modifiedExternally }
        } else if expectedFingerprint != nil {
            throw .modifiedExternally
        }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .writeFailed(error.localizedDescription)
        }

        let tempPath = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .writeFailed(Self.errnoString()) }
        var failure: String?
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        if !written { failure = Self.errnoString() }
        if failure == nil, fchmod(fd, 0o600) != 0 { failure = Self.errnoString() }
        if failure == nil, fsync(fd) != 0 { failure = Self.errnoString() }
        close(fd)
        if failure == nil, rename(tempPath, url.path) != 0 { failure = Self.errnoString() }
        if let failure {
            unlink(tempPath)
            throw .writeFailed(failure)
        }
        return LoadedConfig(document: document, fingerprint: Self.fingerprint(data), permissions: 0o600)
    }

    private func lstatInfo() throws(ConfigError) -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw .unreadable(Self.errnoString())
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
