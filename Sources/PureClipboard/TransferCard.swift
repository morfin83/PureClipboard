import AppKit
import PureClipboardCore
import SwiftUI
import UniformTypeIdentifiers

struct TransferCard: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    private var transfer: TransferController { model.transfer }

    var body: some View {
        Card(title: "Přenos souborů do telefonu", symbol: "arrow.up.doc") {
            VStack(alignment: .leading, spacing: 14) {
                header
                connection
                dropZone
                if let notice = transfer.notice {
                    NoticeBox(message: notice, color: Theme.warning)
                }
                if transfer.jobs.isEmpty {
                    Text("Zatím nic neodesíláte. Přetáhněte sem soubory, nebo je pošlete z Finderu Rychlou akcí.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    VStack(spacing: 1) {
                        ForEach(transfer.jobs) { job in
                            TransferRow(job: job, speed: transfer.speeds[job.id] ?? 0)
                            if job.id != transfer.jobs.last?.id { Divider().overlay(Theme.cardBorder) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    if transfer.jobs.contains(where: { $0.state.isFinished }) {
                        Button("Vyčistit hotové") { transfer.clearFinished() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Text("Soubor se posílá po dílech přes ADB. Po pozastavení, výpadku spojení nebo restartu aplikace se pokračuje od posledního doručeného místa, nezačíná se znovu. Hotový soubor se ověří kontrolním součtem a teprve potom se objeví ve složce Stažené v telefonu; existující soubor se nikdy nepřepíše.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 46, height: 46)
                .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Mac → telefon")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Cíl: Stažené v telefonu · kabel USB nebo Wi‑Fi")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            StatusPill(text: statusText, color: statusColor)
        }
    }

    private var statusText: String {
        if transfer.adbPath == nil { return "Chybí adb" }
        let active = transfer.activeCount
        return active > 0 ? "Probíhá (\(active))" : "Připraveno"
    }

    private var statusColor: Color {
        if transfer.adbPath == nil { return Theme.warning }
        return transfer.activeCount > 0 ? Theme.accent : Theme.secondaryText
    }

    @ViewBuilder
    private var connection: some View {
        if transfer.adbPath == nil {
            NoticeBox(message: "Nástroj adb nebyl nalezen. Nainstalujte ho příkazem „brew install android-platform-tools“ a znovu otevřete aplikaci.", color: Theme.warning)
        }
        VStack(alignment: .leading, spacing: 8) {
            InfoRow(label: "Kabel USB", value: "použije se automaticky, když je telefon připojený a ladění povolené")
            HStack(spacing: 8) {
                Text("Adresa telefonu")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 120, alignment: .leading)
                TextField("100.x.x.x:5555", text: Bindable(transfer).endpointText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { transfer.saveEndpoint() }
                    .accessibilityIdentifier("transfer.endpoint")
                Button("Uložit") { transfer.saveEndpoint() }
                    .disabled(!transfer.endpointIsValid)
            }
            if let hint = transfer.suggestedEndpoint(from: model.remote.peers) {
                HStack(spacing: 8) {
                    Text("Tip: \(hint.name) má adresu \(hint.endpoint)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Button("Použít") { transfer.useSuggestion(hint.endpoint) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(targeted ? Theme.accent : Theme.secondaryText)
            Text(targeted ? "Pusťte soubory k odeslání" : "Přetáhněte sem soubory")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Button("Přidat soubory…") { transfer.chooseFiles() }
                .accessibilityIdentifier("transfer.add")
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background((targeted ? Theme.accent.opacity(0.14) : Color.white.opacity(0.03)), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Theme.accent : Theme.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            transfer.add(urls: files)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let job: TransferJob
    let speed: Double

    private var transfer: TransferController { model.transfer }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.sourceName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(route)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let link = job.link { LinkTag(link: link) }
                buttons
            }
            if showsProgress {
                ProgressView(value: job.fraction)
                    .tint(Theme.accent)
                    .progressViewStyle(.linear)
            }
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    private var showsProgress: Bool {
        job.state != .completed && job.state != .canceled
    }

    private var route: String {
        let folder = job.destinationDirectory == TransferSettings.defaultDestination ? "Stažené" : job.destinationDirectory
        let name = job.destinationName ?? job.sourceName
        let source = (job.sourcePath as NSString).deletingLastPathComponent
        return "\((source as NSString).abbreviatingWithTildeInPath)  →  telefon · \(folder)/\(name)"
    }

    private var icon: String {
        switch job.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle"
        case .paused, .pausing: "pause.circle.fill"
        default: "arrow.up.circle.fill"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .completed: Theme.accent
        case .failed: Theme.danger
        case .paused, .pausing: Theme.warning
        default: Theme.secondaryText
        }
    }

    private var detailColor: Color {
        job.state == .failed ? Theme.danger : (job.state == .paused ? Theme.warning : Theme.secondaryText)
    }

    private var detail: String {
        let done = TransferFormat.bytes(job.bytesDone)
        let total = TransferFormat.bytes(job.size)
        switch job.state {
        case .queued: return "Čeká ve frontě · \(total)"
        case .preparing: return "Příprava (kontrolní součet souboru) · \(total)"
        case .running:
            let rate = TransferFormat.speed(speed)
            let eta = TransferSpeedMeter.eta(remaining: job.size - job.bytesDone, bytesPerSecond: speed).map { " · zbývá \(TransferFormat.duration($0))" } ?? ""
            return "\(done) z \(total) · \(Int(job.fraction * 100)) % · \(rate)\(eta)"
        case .pausing: return "Pozastavuje se po dokončení aktuálního dílu · \(done) z \(total)"
        case .paused: return (job.message ?? "Pozastaveno") + " · \(done) z \(total)"
        case .verifying: return "Ověřuji kontrolní součet na telefonu · \(total)"
        case .completed:
            let rate = job.averageBytesPerSecond.map { " · průměr \(TransferFormat.speed($0))" } ?? ""
            return "Hotovo · \(total)\(rate)"
        case .failed: return job.message ?? "Přenos selhal."
        case .canceled: return "Zrušeno"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .queued, .preparing, .running:
                Button("Pozastavit") { transfer.pause(job) }
                Button("Zrušit") { transfer.cancel(job) }
            case .pausing:
                Button("Pokračovat") { transfer.resume(job) }
            case .paused:
                if job.pauseReason == .mobileData {
                    Button("Přesto poslat") { transfer.resumeOnMobileData(job) }
                } else {
                    Button("Pokračovat") { transfer.resume(job) }
                }
                Button("Zrušit") { transfer.cancel(job) }
            case .verifying:
                EmptyView()
            case .failed:
                Button("Zkusit znovu") { transfer.resume(job) }
                Button("Odebrat") { transfer.remove(job) }
            case .completed, .canceled:
                Button("Odebrat") { transfer.remove(job) }
            }
        }
        .controlSize(.small)
    }
}

private struct LinkTag: View {
    let link: TransferLink

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(link == .mobile ? Theme.warning : Theme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.05), in: Capsule())
    }

    private var text: String {
        switch link {
        case .usb: "Kabel USB"
        case .wifi: "Wi‑Fi"
        case .mobile: "Mobilní data"
        case .unknown: "Síť"
        }
    }

    private var symbol: String {
        switch link {
        case .usb: "cable.connector"
        case .wifi: "wifi"
        case .mobile: "antenna.radiowaves.left.and.right"
        case .unknown: "network"
        }
    }
}

enum TransferFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
