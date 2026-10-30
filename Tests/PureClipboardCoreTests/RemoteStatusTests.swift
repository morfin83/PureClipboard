import Foundation
import Testing
@testable import PureClipboardCore

private func status(_ sent: Int64, _ received: Int64, online: Bool = true, includePeer: Bool = true) throws -> RemoteStatus {
    let peer = includePeer ? """
      "peer-a": {
        "ID": "peer-a", "HostName": "S25", "OS": "android",
        "Online": \(online), "Active": true,
        "TxBytes": \(sent), "RxBytes": \(received),
        "CurAddr": "10.0.0.1:41641", "Relay": ""
      }
    """ : ""
    let json = """
    {"BackendState":"Running", "Self":{"HostName":"Mac"}, "Peer":{\(peer)}}
    """
    return try JSONDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
}

@Suite struct RemoteStatusTests {
    @Test func decodesLocalPeerCountersAndRoute() throws {
        let snapshot = try status(1_000, 2_000)
        #expect(snapshot.localName == "Mac")
        #expect(snapshot.backendState == "Running")
        #expect(snapshot.peers.count == 1)
        #expect(snapshot.peers[0].route == .direct)
        #expect(snapshot.peers[0].sentBytes == 1_000)
        #expect(snapshot.peers[0].receivedBytes == 2_000)
    }

    @Test func computesRatesFromDeltasAndResetsOnCounterRestart() throws {
        var calculator = RemoteRateCalculator()
        let first = calculator.update(try status(1_000, 2_000), at: 10)
        #expect(first[0].sentBytesPerSecond == 0)
        let second = calculator.update(try status(3_000, 3_000), at: 12)
        #expect(second[0].sentBytesPerSecond == 1_000)
        #expect(second[0].receivedBytesPerSecond == 500)
        let restarted = calculator.update(try status(10, 20), at: 14)
        #expect(restarted[0].sentBytesPerSecond == 0)
        let again = calculator.update(try status(30, 60), at: 16)
        #expect(again[0].sentBytesPerSecond == 10)
        #expect(again[0].receivedBytesPerSecond == 20)
    }

    @Test func offlineOrMissingPeerCannotShowStaleSpeed() throws {
        var calculator = RemoteRateCalculator()
        _ = calculator.update(try status(1_000, 2_000), at: 10)
        let offline = calculator.update(try status(5_000, 6_000, online: false), at: 12)
        #expect(offline[0].sentBytesPerSecond == 0)
        #expect(offline[0].receivedBytesPerSecond == 0)
        let returned = calculator.update(try status(7_000, 8_000), at: 14)
        #expect(returned[0].sentBytesPerSecond == 0)
        _ = calculator.update(try status(9_000, 10_000, includePeer: false), at: 16)
        let appeared = calculator.update(try status(12_000, 13_000), at: 18)
        #expect(appeared[0].receivedBytesPerSecond == 0)
    }
}


@Suite struct RemoteStatusRobustnessTests {
    private func decode(_ json: String) throws -> RemoteStatus {
        try JSONDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
    }

    @Test func missingOptionalFieldsFallBackToSafeDefaults() throws {
        let snapshot = try decode(#"{"BackendState":"Running","Peer":{"p":{"ID":"p"}}}"#)
        #expect(snapshot.localName == "Tento Mac")
        #expect(snapshot.peers.count == 1)
        let peer = snapshot.peers[0]
        #expect(peer.name == "Neznámé zařízení" && peer.os.isEmpty)
        #expect(!peer.online && !peer.active)
        #expect(peer.sentBytes == 0 && peer.receivedBytes == 0)
        #expect(peer.route == .idle)
    }

    @Test func noPeersAndUnknownKeysAreHarmless() throws {
        #expect(try decode(#"{"BackendState":"Running","Self":{"HostName":"Mac"}}"#).peers.isEmpty)
        let extra = try decode(#"{"BackendState":"Running","Version":"1.9","Health":["x"],"Peer":{"p":{"ID":"p","HostName":"A","Unknown":{"a":1}}}}"#)
        #expect(extra.peers.map(\.name) == ["A"])
    }

    @Test func notRunningBackendStatesArePreserved() throws {
        for state in ["NeedsLogin", "Stopped", "Starting", "NoState"] {
            #expect(try decode(#"{"BackendState":"\#(state)"}"#).backendState == state)
        }
    }

    @Test func garbageIsRejectedInsteadOfCrashing() {
        for raw in ["", "nonsense", "[]", "null", #"{"Peer":{}}"#, #"{"BackendState":5}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(RemoteStatus.self, from: Data(raw.utf8)) }
        }
    }

    @Test func negativeCountersAreClampedToZero() throws {
        let snapshot = try decode(#"{"BackendState":"Running","Peer":{"p":{"ID":"p","Online":true,"Active":true,"TxBytes":-5,"RxBytes":-9}}}"#)
        #expect(snapshot.peers[0].sentBytes == 0 && snapshot.peers[0].receivedBytes == 0)
    }

    @Test func routeClassification() throws {
        func route(_ fields: String) throws -> RemoteRoute {
            try decode(#"{"BackendState":"Running","Peer":{"p":{"ID":"p","Online":true,"Active":true,\#(fields)}}}"#).peers[0].route
        }
        #expect(try route(#""CurAddr":"1.2.3.4:5""#) == .direct)
        #expect(try route(#""CurAddr":"","PeerRelay":"relay.example:1""#) == .peerRelay)
        #expect(try route(#""CurAddr":"","Relay":"fra""#) == .relay)
        #expect(try route(#""CurAddr":"","Relay":"""#) == .unknown)
        let inactive = try decode(#"{"BackendState":"Running","Peer":{"p":{"ID":"p","Online":true,"Active":false,"CurAddr":"1.2.3.4:5"}}}"#)
        #expect(inactive.peers[0].route == .idle)
    }

    @Test func rateNeverBecomesNaNInfiniteOrNegative() throws {
        var calculator = RemoteRateCalculator()
        _ = calculator.update(try status(0, 0), at: 10)
        let sameInstant = calculator.update(try status(5_000, 5_000), at: 10)
        #expect(sameInstant[0].sentBytesPerSecond == 0 && sameInstant[0].receivedBytesPerSecond == 0)
        let backwards = calculator.update(try status(9_000, 9_000), at: 5)
        #expect(backwards[0].sentBytesPerSecond == 0)
        let huge = calculator.update(try status(Int64.max, Int64.max), at: 20)
        #expect(huge[0].sentBytesPerSecond.isFinite && huge[0].sentBytesPerSecond >= 0)
        #expect(huge[0].receivedBytesPerSecond.isFinite && huge[0].receivedBytesPerSecond >= 0)
    }

    @Test func peersAreSortedAndDoNotRetainHistoryAfterReset() throws {
        let snapshot = try decode(#"{"BackendState":"Running","Peer":{"b":{"ID":"b","HostName":"zeta"},"a":{"ID":"a","HostName":"Alfa"},"c":{"ID":"c","HostName":"beta"}}}"#)
        #expect(snapshot.peers.map(\.name) == ["Alfa", "beta", "zeta"])
        var calculator = RemoteRateCalculator()
        _ = calculator.update(try status(1_000, 1_000), at: 1)
        calculator.reset()
        #expect(calculator.update(try status(9_000, 9_000), at: 2)[0].sentBytesPerSecond == 0)
    }

    @Test func storedModeValueStaysCompatibleWithTheNewLabel() {
        #expect(PureClipboardConfig.defaults.integrations.pureRemote.mode == "actionResults")
        #expect(IntegrationMode.label(for: "actionResults") == "Živý přehled")
        #expect(PureClipboardConfig.defaults.validationIssues().isEmpty)
    }
}
