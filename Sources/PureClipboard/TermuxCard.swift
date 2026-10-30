import AppKit
import PureClipboardCore
import SwiftUI

struct TermuxCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmInstall = false
    @State private var confirmRemove = false
    @State private var plan: [String] = []
    @State private var host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "").lowercased()

    private var controller: TermuxController { model.termux }

    var body: some View {
        let state = controller.state
        Card(title: "Termux – S25 ↔ Mac", symbol: "candybarphone") {
            VStack(alignment: .leading, spacing: 12) {
                HStack { statusPill(state); Spacer() }
                Text("Text se přenáší jen na váš příkaz. Telefon se připojí k Macu přes SSH (Tailscale) vaším stávajícím klíčem a spustí pomocný program Pure Clipboard. Nic na telefonu ani na Macu nenaslouchá a přenos Termuxu nic nesleduje. Přijatý text se do schránky Macu dostane až tlačítkem Kopírovat. Nastavení SSH se nemění.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Pomocný program", value: state.helperInstalled ? controller.helperPath.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "není nainstalován",
                            color: state.helperInstalled ? Theme.primaryText : Theme.secondaryText, mono: state.helperInstalled)
                    InfoRow(label: "Pošta", value: state.mailboxReady ? "připravena · přijato \(state.inboxCount) · k odeslání \(state.outboxCount)" : "není připravena",
                            color: state.mailboxReady ? Theme.accent : Theme.secondaryText)
                    InfoRow(label: "Poslední událost", value: eventText)
                }

                if let error = controller.error { NoticeBox(message: error, color: Theme.danger) }
                if let message = controller.notice { NoticeBox(message: message, color: Theme.accent, icon: "checkmark.circle.fill") }
                if let result = controller.testResult { NoticeBox(message: result, color: Theme.accent, icon: "checkmark.seal.fill") }

                HStack(spacing: 8) {
                    Button {
                        plan = controller.installPlan()
                        confirmInstall = true
                    } label: {
                        Label(state.isInstalled ? "Aktualizovat kanál" : "Připravit kanál", systemImage: "square.and.arrow.down")
                    }
                    .disabled(controller.bundledHelper == nil || (state.isInstalled && state.helperInstalled && controller.bundledHelper.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: URL(fileURLWithPath: controller.helperPath)))))
                    if state.mailboxReady || state.helperInstalled {
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Odebrat kanál", systemImage: "trash") }
                    }
                    Button { controller.runTest() } label: { Label("Otestovat (bez zápisu)", systemImage: "checkmark.seal") }
                }

                if state.isInstalled {
                    Divider().overlay(Theme.cardBorder)
                    mailboxSections
                    Divider().overlay(Theme.cardBorder)
                    setupSection
                }

                Text("Příjem i odesílání respektují přepínač Termux a ochranu citlivých údajů. Texty v poště se po hodině samy smažou (nejvýš 20 položek). Auto Copy se netýká výslovných příkazů.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Připravit kanál pro Termux?", isPresented: $confirmInstall) {
            Button("Připravit") { controller.install() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(plan.joined(separator: "\n"))
        }
        .confirmationDialog("Odebrat kanál pro Termux?", isPresented: $confirmRemove) {
            Button("Odebrat", role: .destructive) { controller.remove() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Smaže se složka s poštou (včetně čekajících textů) a pomocný program, pokud ho nepoužívá jiná integrace. SSH ani Tailscale se nemění.")
        }
    }

    @ViewBuilder private var mailboxSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Přijato z S25")
            if controller.inbox.isEmpty {
                Text("Nic nečeká. V Termuxu spusťte: pcr tomac").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
            }
            ForEach(controller.inbox) { item in
                itemRow(item) {
                    Button("Kopírovat") { controller.copyToClipboard(item) }
                    Button("Smazat", role: .destructive) { controller.discard(item, from: .inbox) }
                }
            }
            sectionTitle("K odeslání do S25")
            ForEach(controller.outbox) { item in
                itemRow(item) { Button("Zrušit", role: .destructive) { controller.discard(item, from: .outbox) } }
            }
            HStack(spacing: 8) {
                Button { controller.sendClipboardToPhone() } label: { Label("Odeslat schránku Macu do S25", systemImage: "paperplane") }
                Button { controller.addSampleToInbox() } label: { Label("Zkušební položka", systemImage: "tray.and.arrow.down") }
            }
            Text("Tlačítko „Odeslat“ přečte schránku Macu jednou, právě teď. Telefon si text vyzvedne příkazem pcr frommac.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Skript pcr pro Termux (jednorázově)")
            HStack {
                Text("Adresa Macu v Tailscale")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                TextField("pavels-macbook-pro", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 260)
            }
            Text(controller.bootstrapCommand(host: host))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.bootstrapCommand(host: host), forType: .string)
            } label: { Label("Zkopírovat příkaz", systemImage: "doc.on.doc") }
            Text("Příkaz spusťte v Termuxu na S25 (jednou). Potřebuje balíček openssh a pro schránku telefonu balíček termux-api spolu s aplikací Termux:API. Pak: pcr tomac (telefon → Mac), pcr frommac (Mac → telefon), pcr doctor.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.secondaryText)
    }

    private func itemRow<Actions: View>(_ item: TermuxItem, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preview(item.text)).font(.system(size: 12)).foregroundStyle(Theme.primaryText).lineLimit(1)
                Text("\(item.createdAt.formatted(date: .omitted, time: .standard)) · \(item.characters) znaků · \(item.device)")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText)
            }
            Spacer(minLength: 0)
            actions().controlSize(.small)
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func preview(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.count > 70 ? String(line.prefix(70)) + "…" : line
    }

    private func statusPill(_ state: TermuxChannelState) -> some View {
        if !state.isInstalled { return StatusPill(text: "Nepřipraveno", color: Theme.warning) }
        return StatusPill(text: state.inboxCount > 0 ? "Přijato \(state.inboxCount)" : "Připraveno", color: Theme.accent)
    }

    private var eventText: String {
        guard let event = controller.event else { return "zatím žádná" }
        let time = event.timestamp.formatted(date: .abbreviated, time: .standard)
        switch (event.result, event.reason) {
        case ("copied", "received"): return "\(time) · přijato z S25 (\(event.characters) znaků)"
        case ("copied", "delivered"): return "\(time) · doručeno do S25 (\(event.characters) znaků)"
        case ("copied", "queued"): return "\(time) · čeká na S25 (\(event.characters) znaků)"
        case ("copied", _): return "\(time) · zkopírováno do schránky (\(event.characters) znaků)"
        default:
            var text = "\(time) · přeskočeno: \(HookReasonLabel.text(event.reason))"
            if !event.findings.isEmpty { text += " (\(event.findings.joined(separator: ", ")))" }
            return text
        }
    }
}
