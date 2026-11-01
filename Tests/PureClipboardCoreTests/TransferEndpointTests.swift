import Foundation
import Testing
@testable import PureClipboardCore

/// A fake `adb`: answers from a closure, so a test can change the phone's state between calls (reboot, new port).
private final class ScriptedAdb: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var connects: [String] = []
    var handler: @Sendable ([String]) -> ProcessResult = { _ in ProcessResult(status: 0) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        if arguments.first == "connect" { lock.withLock { connects.append(arguments[1]) } }
        return handler(arguments)
    }
}

private let mdnsLine = "adb-R5GL127QFPN-or53q1\t_adb-tls-connect._tcp\t10.0.0.83:35857"

@Suite struct TransferEndpointTests {
    @Test func parsesOnlyTheConnectServices() {
        let output = """
        adb-R5GL127QFPN-or53q1\t_adb-tls-connect._tcp\t10.0.0.83:35857
        printer\t_ipp._tcp\t10.0.0.9:631
        adb-R5GL127QFPN-or53q1\t_adb-tls-pairing._tcp\t10.0.0.83:40111
        """
        let parsed = AdbPhoneResolver.parseMDNS(output)
        #expect(parsed.count == 1)
        #expect(parsed.first?.endpoint == "10.0.0.83:35857")
        #expect(parsed.first?.name.contains("R5GL127QFPN") == true)
    }

    @Test func findsThePhoneAfterItsPortChanged() async throws {
        let adb = ScriptedAdb()
        // The saved address is dead; the phone answers on a new port found through mDNS.
        adb.handler = { args in
            switch args.first {
            case "devices":
                let answering = adb.connects.contains("10.0.0.83:35857")
                return ProcessResult(status: 0, stdout: "List of devices attached\n" + (answering ? "10.0.0.83:35857\tdevice\n" : ""))
            case "connect":
                return ProcessResult(status: 0, stdout: "connected to \(args[1])")
            case "mdns":
                return ProcessResult(status: 0, stdout: mdnsLine + "\n")
            default:
                if args.contains(where: { $0.contains("ro.serialno") }) { return ProcessResult(status: 0, stdout: "R5GL127QFPN\n") }
                return ProcessResult(status: 0, stdout: "")
            }
        }
        let resolver = AdbPhoneResolver(adb: "/x/adb", runner: adb)
        let target = try await resolver.resolve(settings: TransferSettings(endpoint: "100.92.44.15:41797", phoneSerial: "R5GL127QFPN"))
        #expect(target.endpoint == "10.0.0.83:35857")
        #expect(target.serial == "R5GL127QFPN")
        #expect(adb.connects.contains("10.0.0.83:35857"))
    }

    @Test func withoutTheSerialNoDiscoveryIsAttempted() async throws {
        let adb = ScriptedAdb()
        adb.handler = { args in
            args.first == "devices" ? ProcessResult(status: 0, stdout: "List of devices attached\n") : ProcessResult(status: 0)
        }
        let resolver = AdbPhoneResolver(adb: "/x/adb", runner: adb)
        await #expect(throws: TransferError.self) {
            try await resolver.resolve(settings: TransferSettings(endpoint: "100.92.44.15:41797"))
        }
        #expect(!adb.connects.contains("10.0.0.83:35857"))
    }

    @Test func settingsWithoutSerialStillDecode() throws {
        let old = #"{"destinationDirectory":"/sdcard/Download","endpoint":"100.92.44.15:5555"}"#
        let decoded = try JSONDecoder().decode(TransferSettings.self, from: Data(old.utf8))
        #expect(decoded.endpoint == "100.92.44.15:5555")
        #expect(decoded.phoneSerial == nil)
    }
}
