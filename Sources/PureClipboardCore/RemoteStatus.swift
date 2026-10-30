import Foundation

/// A read-only snapshot of the local Tailscale client's view of the tailnet.
/// Tx/Rx counters are always from this Mac's perspective.
public struct RemoteStatus: Decodable, Sendable {
    public let backendState: String
    public let localName: String
    public let peers: [RemotePeer]

    private enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case local = "Self"
        case peers = "Peer"
    }

    private struct LocalPeer: Decodable {
        let name: String
        private enum CodingKeys: String, CodingKey { case name = "HostName" }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try values.decode(String.self, forKey: .backendState)
        localName = try values.decodeIfPresent(LocalPeer.self, forKey: .local)?.name ?? "Tento Mac"
        let peerMap = try values.decodeIfPresent([String: RemotePeer].self, forKey: .peers) ?? [:]
        peers = peerMap.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct RemotePeer: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let os: String
    public let online: Bool
    public let active: Bool
    public let sentBytes: Int64
    public let receivedBytes: Int64
    public let directAddress: String?
    public let relay: String?
    public let peerRelay: String?

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "HostName"
        case os = "OS"
        case online = "Online"
        case active = "Active"
        case sentBytes = "TxBytes"
        case receivedBytes = "RxBytes"
        case directAddress = "CurAddr"
        case relay = "Relay"
        case peerRelay = "PeerRelay"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Neznámé zařízení"
        os = try values.decodeIfPresent(String.self, forKey: .os) ?? ""
        online = try values.decodeIfPresent(Bool.self, forKey: .online) ?? false
        active = try values.decodeIfPresent(Bool.self, forKey: .active) ?? false
        sentBytes = max(0, try values.decodeIfPresent(Int64.self, forKey: .sentBytes) ?? 0)
        receivedBytes = max(0, try values.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0)
        directAddress = try values.decodeIfPresent(String.self, forKey: .directAddress)
        relay = try values.decodeIfPresent(String.self, forKey: .relay)
        peerRelay = try values.decodeIfPresent(String.self, forKey: .peerRelay)
    }

    public var route: RemoteRoute {
        guard online, active else { return .idle }
        if directAddress?.isEmpty == false { return .direct }
        if peerRelay?.isEmpty == false { return .peerRelay }
        if relay?.isEmpty == false { return .relay }
        return .unknown
    }
}

public enum RemoteRoute: Sendable {
    case direct, peerRelay, relay, idle, unknown
}

public struct RemotePeerRate: Sendable, Identifiable {
    public let peer: RemotePeer
    public let sentBytesPerSecond: Double
    public let receivedBytesPerSecond: Double

    public var id: String { peer.id }
}

/// Turns cumulative per-peer counters into current rates, without retaining traffic history.
public struct RemoteRateCalculator: Sendable {
    private struct Sample: Sendable {
        let at: TimeInterval
        let sent: Int64
        let received: Int64
    }

    private var previous: [String: Sample] = [:]

    public init() {}

    public mutating func update(_ status: RemoteStatus, at time: TimeInterval) -> [RemotePeerRate] {
        var next: [String: Sample] = [:]
        let rates = status.peers.map { peer -> RemotePeerRate in
            var sent = 0.0
            var received = 0.0
            if peer.online {
                if let old = previous[peer.id], time > old.at,
                   peer.sentBytes >= old.sent, peer.receivedBytes >= old.received {
                    let interval = time - old.at
                    sent = Double(peer.sentBytes - old.sent) / interval
                    received = Double(peer.receivedBytes - old.received) / interval
                }
                next[peer.id] = Sample(at: time, sent: peer.sentBytes, received: peer.receivedBytes)
            }
            return RemotePeerRate(peer: peer, sentBytesPerSecond: sent, receivedBytesPerSecond: received)
        }
        previous = next
        return rates
    }

    public mutating func reset() { previous.removeAll() }
}
