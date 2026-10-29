import PureClipboardCore
import SwiftUI

struct TerminalCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmInstall = false
    @State private var confirmRemove = false
    @State private var confirmRealTest = false
    @State private var plan: [String] = []

    private var controller: TerminalController { model.terminal }

    var body: some View {
        let state = controller.state
        Card(title: "Apple Terminal – příkaz pclip", symbol: "apple.terminal") {
            VStack(alignment: .leading, spacing: 12) {
                HStack { statusPill(state); Spacer() }
                Text("Terminal.app nepředává výstup příkazů žádnému oficiálnímu hooku, a čtení okna nebo historie by bylo sledování obrazovky. Proto se kopíruje jen výstup příkazu, který sami spustíte přes pclip: pclip swift build. Stačí zapnutá integrace Terminal; Auto Copy může zůstat vypnuté. Citlivé údaje se při zapnuté ochraně nekopírují; při chybovém kódu se připojí řádek [exit N].")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Soubor .zshrc", value: controller.zshrcPath, mono: true)
                    InfoRow(label: "Blok v .zshrc", value: state.blockPresent ? "přidán" : "nepřidán",
                            color: state.blockPresent ? Theme.accent : Theme.secondaryText)
                    InfoRow(label: "Skript", value: scriptText(state), color: state.snippetCurrent == false ? Theme.warning : Theme.primaryText)
                    InfoRow(label: "Pomocný program", value: state.helperInstalled ? "nainstalován" : "není nainstalován",
                            color: state.helperInstalled ? Theme.primaryText : Theme.secondaryText)
                    InfoRow(label: "Poslední událost", value: eventText)
                }

                ForEach(state.notes, id: \.self) { NoticeBox(message: $0, color: Theme.warning, icon: "info.circle.fill") }
                if let problem = state.problem { NoticeBox(message: problem, color: Theme.danger) }
                if let error = controller.error { NoticeBox(message: error, color: Theme.danger) }
                if let message = controller.notice { NoticeBox(message: message, color: Theme.accent, icon: "checkmark.circle.fill") }
                if let result = controller.testResult { NoticeBox(message: result, color: Theme.accent, icon: "checkmark.seal.fill") }

                HStack(spacing: 8) {
                    Button {
                        plan = controller.installPlan()
                        confirmInstall = true
                    } label: {
                        Label(state.isInstalled ? "Aktualizovat" : "Nainstalovat pclip", systemImage: "square.and.arrow.down")
                    }
                    .disabled(controller.bundledHelper == nil || (state.isInstalled && state.snippetCurrent == true && state.helperInstalled))
                    if state.blockPresent || state.snippetInstalled {
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Odebrat pclip", systemImage: "trash") }
                    }
                }
                HStack(spacing: 8) {
                    Button { controller.runTest(writeToClipboard: false) } label: { Label("Otestovat (bez zápisu)", systemImage: "checkmark.seal") }
                    Button { confirmRealTest = true } label: { Label("Test se schránkou…", systemImage: "doc.on.clipboard") }
                }
                Text("Instalace jen připíše jeden označený blok na konec .zshrc (po záloze); vaše řádky, včetně stávajícího clipboard.zsh a cliprun, se nemění. Příkaz spouštíte vy, aplikace sama žádný proces nespouští.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Nainstalovat příkaz pclip?", isPresented: $confirmInstall) {
            Button("Nainstalovat") { controller.install() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(plan.joined(separator: "\n"))
        }
        .confirmationDialog("Odebrat příkaz pclip?", isPresented: $confirmRemove) {
            Button("Odebrat", role: .destructive) { controller.remove() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Z .zshrc se (po záloze) odstraní pouze blok Pure Clipboard a smaže se skript pclip. Ostatní řádky zůstanou.")
        }
        .confirmationDialog("Přepsat schránku ukázkovým textem?", isPresented: $confirmRealTest) {
            Button("Přepsat schránku") { controller.runTest(writeToClipboard: true) }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Test zkopíruje neškodný ukázkový výstup a tím nahradí aktuální obsah schránky.")
        }
    }

    private func statusPill(_ state: ZshIntegrationState) -> some View {
        if state.problem != nil { return StatusPill(text: "Nelze ověřit", color: Theme.danger) }
        if state.blockPresent && !state.snippetInstalled { return StatusPill(text: "Chybí skript", color: Theme.danger) }
        if !state.isInstalled { return StatusPill(text: "Nenainstalováno", color: Theme.warning) }
        if state.snippetCurrent == false { return StatusPill(text: "Doporučena aktualizace", color: Theme.warning) }
        return StatusPill(text: "Nainstalováno", color: Theme.accent)
    }

    private func scriptText(_ state: ZshIntegrationState) -> String {
        guard state.snippetInstalled else { return "není nainstalován" }
        return state.snippetCurrent == true ? "aktuální" : "starší verze"
    }

    private var eventText: String {
        guard let event = controller.event else { return "zatím žádná" }
        let time = event.timestamp.formatted(date: .abbreviated, time: .standard)
        if event.result == "copied" { return "\(time) · zkopírováno (\(event.characters) znaků)" }
        var text = "\(time) · přeskočeno: \(HookReasonLabel.text(event.reason))"
        if !event.findings.isEmpty { text += " (\(event.findings.joined(separator: ", ")))" }
        return text
    }
}
