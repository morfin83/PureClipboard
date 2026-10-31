import Foundation

// MARK: Process running

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

/// Runs a child process without a shell. A watchdog kills it on timeout and Swift task cancellation kills it at once.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    private final class Box: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var timedOut = false
        private var cancelled = false
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        func markCancelled() { lock.lock(); cancelled = true; lock.unlock() }
        var flags: (timedOut: Bool, cancelled: Bool) { lock.lock(); defer { lock.unlock() }; return (timedOut, cancelled) }
        func terminate() {
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = box.process
                    let out = Pipe()
                    let err = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardOutput = out
                    process.standardError = err
                    process.standardInput = FileHandle.nullDevice
                    do { try process.run() } catch {
                        continuation.resume(throwing: TransferError.commandFailed(error.localizedDescription))
                        return
                    }
                    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    watchdog.schedule(deadline: .now() + timeout)
                    watchdog.setEventHandler {
                        box.markTimedOut()
                        box.terminate()
                    }
                    watchdog.resume()

                    var outData = Data()
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        outData = out.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        errData = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()
                    watchdog.cancel()

                    let flags = box.flags
                    if flags.cancelled { continuation.resume(throwing: CancellationError()); return }
                    if flags.timedOut { continuation.resume(throwing: TransferError.timedOut); return }
                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            box.markCancelled()
            box.terminate()
        }
    }
}

// MARK: Phone operations

/// Everything the transfer engine needs from the phone. Implemented over `adb`; tests use a local folder.
public protocol PhoneFiles: Sendable {
    func freeBytes(at path: String) async throws -> Int64
    func exists(_ path: String) async throws -> Bool
    func size(of path: String) async throws -> Int64?
    func makeDirectory(_ path: String) async throws
    func truncate(_ path: String, to size: Int64) async throws
    func push(local: URL, to remote: String, timeout: TimeInterval) async throws
    /// Appends the chunk file to `file`, deletes the chunk and returns the new size of `file`.
    func append(chunk: String, to file: String) async throws -> Int64
    func sha256(of path: String) async throws -> String
    /// Moves without overwriting; throws `destinationBusy` when the target exists.
    func move(_ from: String, to: String) async throws
    /// Removes a path below the Pure Clipboard staging folder only.
    func removeStaging(_ path: String) async throws
    /// Removes `<base>/.pureclipboard` when nothing is left in it (best effort, never throws).
    func removeStagingRootIfEmpty(base: String) async
    /// Asks the phone's media index to pick up a new file so it appears in Gallery (best effort, never throws).
    func refreshMedia(_ path: String) async
}

public extension PhoneFiles {
    func refreshMedia(_ path: String) async {}
}

public enum MediaFiles {
    /// Extensions Android indexes as images, video or audio; anything else is left alone.
    private static let indexed: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng",
        "mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi",
        "mp3", "m4a", "aac", "ogg", "oga", "flac", "wav",
    ]

    public static func needsIndexing(_ name: String) -> Bool {
        indexed.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}

public enum PhoneStaging {
    public static let folderName = ".pureclipboard"
    public static func directory(base: String, id: String) -> String { "\(base)/\(folderName)/\(id)" }
    public static func isStagingPath(_ path: String) -> Bool {
        path.contains("/\(folderName)/") && !path.contains("..") && path.hasPrefix("/sdcard/")
    }
}

public struct PhoneTarget: Sendable {
    public var phone: any PhoneFiles
    public var link: TransferLink

    public init(phone: any PhoneFiles, link: TransferLink) {
        self.phone = phone
        self.link = link
    }
}

public protocol PhoneResolving: Sendable {
    func resolve(settings: TransferSettings) async throws -> PhoneTarget
}

public enum ShellQuoting {
    /// Single-quotes a value for the phone's `sh`; embedded quotes become `'\''`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: adb

public enum AdbLocator {
    public static let candidates = [
        "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
    ]

    public static func find() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public struct AdbPhone: PhoneFiles {
    public let adb: String
    public let serial: String
    public let runner: any ProcessRunning

    public init(adb: String, serial: String, runner: any ProcessRunning = SystemProcessRunner()) {
        self.adb = adb
        self.serial = serial
        self.runner = runner
    }

    private func shell(_ command: String, timeout: TimeInterval = 60) async throws -> String {
        let result = try await runner.run(adb, ["-s", serial, "shell", command], timeout: timeout)
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransferError.commandFailed(String(detail.prefix(200)))
        }
        return result.stdout
    }

    public func freeBytes(at path: String) async throws -> Int64 {
        let output = try await shell("df -k \(ShellQuoting.quote(path)) | tail -n 1")
        let tokens = output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let percent = tokens.firstIndex(where: { $0.hasSuffix("%") }), percent >= 1,
              let kilobytes = Int64(tokens[percent - 1]) else {
            throw TransferError.commandFailed("nelze zjistit volné místo")
        }
        return kilobytes * 1_024
    }

    public func exists(_ path: String) async throws -> Bool {
        let output = try await shell("[ -e \(ShellQuoting.quote(path)) ] && echo yes || echo no")
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    public func size(of path: String) async throws -> Int64? {
        let output = try await shell("stat -c %s \(ShellQuoting.quote(path)) 2>/dev/null || echo missing")
        return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await shell("mkdir -p \(ShellQuoting.quote(path))")
    }

    public func truncate(_ path: String, to size: Int64) async throws {
        _ = try await shell("truncate -s \(size) \(ShellQuoting.quote(path))")
    }

    public func push(local: URL, to remote: String, timeout: TimeInterval) async throws {
        let result = try await runner.run(adb, ["-s", serial, "push", local.path, remote], timeout: timeout)
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransferError.commandFailed(String(detail.suffix(200)))
        }
    }

    public func append(chunk: String, to file: String) async throws -> Int64 {
        let c = ShellQuoting.quote(chunk)
        let f = ShellQuoting.quote(file)
        let output = try await shell("cat \(c) >> \(f) && rm -f \(c) && stat -c %s \(f)")
        guard let size = Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TransferError.commandFailed("neočekávaná odpověď telefonu")
        }
        return size
    }

    public func sha256(of path: String) async throws -> String {
        let output = try await shell("sha256sum \(ShellQuoting.quote(path))", timeout: 600)
        guard let token = output.split(whereSeparator: \.isWhitespace).first, token.count == 64 else {
            throw TransferError.commandFailed("sha256sum nevrátil součet")
        }
        return token.lowercased()
    }

    public func move(_ from: String, to: String) async throws {
        let a = ShellQuoting.quote(from)
        let b = ShellQuoting.quote(to)
        let output = try await shell("if [ -e \(b) ]; then echo busy; else mv \(a) \(b) && echo ok; fi")
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw TransferError.destinationBusy }
    }

    public func removeStaging(_ path: String) async throws {
        guard PhoneStaging.isStagingPath(path) else { throw TransferError.commandFailed("odmítnuto mazání mimo pracovní složku") }
        _ = try await shell("rm -rf \(ShellQuoting.quote(path))")
    }

    /// Removes `<base>/.pureclipboard` when nothing is left in it (best effort).
    public func removeStagingRootIfEmpty(base: String) async {
        _ = try? await shell("rmdir \(ShellQuoting.quote("\(base)/\(PhoneStaging.folderName)")) 2>/dev/null; true")
    }

    public func refreshMedia(_ path: String) async {
        guard MediaFiles.needsIndexing(path) else { return }
        let uri = URL(fileURLWithPath: path).absoluteString
        _ = try? await runner.run(adb, [
            "-s", serial, "shell",
            "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(ShellQuoting.quote(uri)) >/dev/null 2>&1",
        ], timeout: 30)
    }
}

public struct AdbPhoneResolver: PhoneResolving {
    public let adb: String
    public let runner: any ProcessRunning

    public init(adb: String, runner: any ProcessRunning = SystemProcessRunner()) {
        self.adb = adb
        self.runner = runner
    }

    struct Device: Equatable {
        var serial: String
        var state: String
        var isNetwork: Bool { serial.contains(":") || serial.contains("._adb") }
    }

    static func parseDevices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("*") else { return nil }
            return Device(serial: parts[0], state: parts[1])
        }
    }

    private func devices() async throws -> [Device] {
        let result = try await runner.run(adb, ["devices"], timeout: 20)
        guard result.status == 0 else { throw TransferError.noPhone("Nástroj adb nevrátil seznam zařízení.") }
        return Self.parseDevices(result.stdout)
    }

    public func resolve(settings: TransferSettings) async throws -> PhoneTarget {
        var listed = try await devices()
        if let usb = listed.first(where: { !$0.isNetwork && $0.state == "device" }) {
            return PhoneTarget(phone: AdbPhone(adb: adb, serial: usb.serial, runner: runner), link: .usb)
        }
        if let endpoint = settings.endpoint {
            _ = try? await runner.run(adb, ["connect", endpoint], timeout: 15)
            listed = try await devices()
            if let wireless = listed.first(where: { $0.serial == endpoint }) {
                switch wireless.state {
                case "device":
                    let phone = AdbPhone(adb: adb, serial: endpoint, runner: runner)
                    return PhoneTarget(phone: phone, link: await Self.networkLink(phone: phone, runner: runner, adb: adb, serial: endpoint))
                case "unauthorized":
                    throw TransferError.noPhone("Telefon nepovolil tento Mac. Potvrďte na telefonu dialog ladění.")
                default:
                    throw TransferError.noPhone("Telefon je ve stavu „\(wireless.state)“.")
                }
            }
            throw TransferError.noPhone("Telefon na adrese \(endpoint) neodpovídá. Zapněte bezdrátové ladění a Wi‑Fi nebo připojte kabel.")
        }
        if listed.contains(where: { $0.state == "unauthorized" }) {
            throw TransferError.noPhone("Telefon nepovolil tento Mac. Potvrďte na telefonu dialog ladění.")
        }
        throw TransferError.noPhone("Telefon není připojený. Připojte kabel, nebo zadejte adresu pro bezdrátové ladění.")
    }

    /// Wi‑Fi switched off on a phone reached over the network means the traffic goes over mobile data.
    static func networkLink(phone: AdbPhone, runner: any ProcessRunning, adb: String, serial: String) async -> TransferLink {
        guard let result = try? await runner.run(adb, ["-s", serial, "shell", "cmd wifi status | head -n 1"], timeout: 15),
              result.status == 0 else { return .unknown }
        let line = result.stdout.lowercased()
        if line.contains("disabled") { return .mobile }
        if line.contains("enabled") { return .wifi }
        return .unknown
    }
}
