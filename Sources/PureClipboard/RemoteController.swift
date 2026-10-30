import Foundation
import Observation
import PureClipboardCore

private enum RemoteReadError: LocalizedError {
    case cliMissing
    case commandFailed
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .cliMissing: "Příkaz Tailscale nebyl nalezen. Nainstalujte nebo zpřístupněte jeho CLI."
        case .commandFailed: "Tailscale nevrátil stav zařízení. Zkontrolujte, zda běží a jste přihlášeni."
        case .invalidOutput: "Tailscale vrátil nečitelný stav zařízení."
        }
    }
}

private enum TailscaleStatusClient {
    private static let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    static func read() throws -> RemoteStatus {
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RemoteReadError.cliMissing
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw RemoteReadError.commandFailed }
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 5)
        watchdog.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RemoteReadError.commandFailed }
        guard let status = try? JSONDecoder().decode(RemoteStatus.self, from: data) else {
            throw RemoteReadError.invalidOutput
        }
        return status
    }
}

@MainActor
@Observable
final class RemoteController {
    enum State: Equatable {
        case waiting
        case loading
        case ready
        case unavailable(String)
    }

    private(set) var state: State = .waiting
    private(set) var localName = "Tento Mac"
    private(set) var peers: [RemotePeerRate] = []
    private(set) var updatedAt: Date?
    private var calculator = RemoteRateCalculator()

    var onlineCount: Int { peers.filter(\.peer.online).count }
    var totalSent: Double { peers.reduce(0) { $0 + $1.sentBytesPerSecond } }
    var totalReceived: Double { peers.reduce(0) { $0 + $1.receivedBytesPerSecond } }

    func monitor() async {
        calculator.reset()
        state = .loading
        while !Task.isCancelled {
            do {
                let status = try await Task.detached(priority: .utility) {
                    try TailscaleStatusClient.read()
                }.value
                guard !Task.isCancelled else { break }
                guard status.backendState == "Running" else {
                    calculator.reset()
                    peers = []
                    updatedAt = nil
                    state = .unavailable("Tailscale není připojený (\(status.backendState)).")
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                localName = status.localName
                peers = calculator.update(status, at: ProcessInfo.processInfo.systemUptime)
                updatedAt = Date()
                state = .ready
            } catch {
                calculator.reset()
                peers = []
                updatedAt = nil
                state = .unavailable(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func stop() {
        calculator.reset()
        peers = []
        updatedAt = nil
        state = .waiting
    }
}
