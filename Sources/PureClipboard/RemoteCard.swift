import PureClipboardCore
import SwiftUI

struct RemoteCard: View {
    @Environment(AppModel.self) private var model
    let enabled: Bool

    var body: some View {
        Card(title: "Pure Remote", symbol: "network") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 48, height: 48)
                        .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Komunikace zařízení")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text("Živý přehled z \(model.remote.localName)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    StatusPill(text: statusText, color: statusColor)
                    Toggle("Pure Remote", isOn: Binding(
                        get: { enabled },
                        set: { value in model.update { $0.integrations.pureRemote.enabled = value } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("integrationToggle.pureRemote")
                }

                if !enabled {
                    NoticeBox(message: "Zapněte přepínač Pure Remote vpravo nahoře na této kartě pro živý přehled Tailscale.", color: Theme.secondaryText, icon: "power")
                } else {
                    switch model.remote.state {
                    case .waiting, .loading:
                        ProgressView("Načítám zařízení z Tailscale…")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    case .unavailable(let message):
                        NoticeBox(message: message, color: Theme.warning)
                    case .ready:
                        overview
                        if model.remote.peers.isEmpty {
                            NoticeBox(message: "V této síti Tailscale nejsou vidět další zařízení.", color: Theme.secondaryText, icon: "desktopcomputer")
                        } else {
                            VStack(spacing: 1) {
                                ForEach(model.remote.peers) { item in
                                    RemotePeerRow(item: item)
                                    if item.id != model.remote.peers.last?.id {
                                        Divider().overlay(Theme.cardBorder)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text("Rychlosti ukazují skutečný provoz mezi tímto Macem a každým zařízením za poslední přibližně 2 sekundy. Jde o momentální přenos, ne o maximální rychlost spojení.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task(id: enabled) {
            if enabled { await model.remote.monitor() }
            else { model.remote.stop() }
        }
    }

    private var overview: some View {
        HStack(spacing: 10) {
            RemoteMetric(symbol: "arrow.up.right", title: "Mac odesílá", value: RemoteRateText.format(model.remote.totalSent))
            RemoteMetric(symbol: "arrow.down.left", title: "Mac přijímá", value: RemoteRateText.format(model.remote.totalReceived))
            RemoteMetric(symbol: "checkmark.circle", title: "Připojeno", value: "\(model.remote.onlineCount)/\(model.remote.peers.count)")
        }
    }

    private var statusText: String {
        if !enabled { return "Vypnuto" }
        switch model.remote.state {
        case .ready: return "Živě"
        case .unavailable: return "Nedostupné"
        case .waiting, .loading: return "Připojuji"
        }
    }

    private var statusColor: Color {
        if !enabled { return Theme.secondaryText }
        switch model.remote.state {
        case .ready: return Theme.accent
        case .unavailable: return Theme.warning
        case .waiting, .loading: return Theme.secondaryText
        }
    }
}

private struct RemoteMetric: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Theme.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.accent.opacity(0.12)))
    }
}

private struct RemotePeerRow: View {
    let item: RemotePeerRate

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: osSymbol)
                .font(.system(size: 17))
                .foregroundStyle(item.peer.online ? Theme.accent : Theme.tertiaryText)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.peer.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(connectionText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Label(RemoteRateText.format(item.sentBytesPerSecond), systemImage: "arrow.up.right")
                    .foregroundStyle(Theme.accent)
                Label(RemoteRateText.format(item.receivedBytesPerSecond), systemImage: "arrow.down.left")
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .monospacedDigit()
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var connectionText: String {
        guard item.peer.online else { return "Odpojeno · \(item.peer.os)" }
        switch item.peer.route {
        case .direct: return "Online · přímé spojení · \(item.peer.os)"
        case .peerRelay: return "Online · přenos přes zařízení · \(item.peer.os)"
        case .relay: return "Online · relé · \(item.peer.os)"
        case .idle: return "Online · nečinné · \(item.peer.os)"
        case .unknown: return "Online · \(item.peer.os)"
        }
    }

    private var osSymbol: String {
        if item.peer.name.localizedLowercase.contains("tv") { return "tv" }
        switch item.peer.os.lowercased() {
        case "android", "ios": return "iphone"
        case "windows", "linux": return "desktopcomputer"
        case "macos": return "laptopcomputer"
        default: return "network"
        }
    }
}

private enum RemoteRateText {
    static func format(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 1_000 && unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        return "\(value.formatted(.number.precision(.fractionLength(value < 10 && unit > 0 ? 1 : 0)))) \(units[unit])"
    }
}
