import PureClipboardCore
import SwiftUI

struct HookCard: View {
    @Environment(AppModel.self) private var model
    let target: HookTarget
    @State private var confirmInstall = false
    @State private var confirmRemove = false
    @State private var confirmRealTest = false
    @State private var plan: [String] = []

    private var controller: HookController { model.controller(for: target) }

    var body: some View {
        let hook = controller.state
        Card(title: "\(target.displayName) – hook", symbol: target == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    statusPill(hook)
                    Spacer()
                }
                Text("Po dokončení odpovědi \(target.displayName) zkopíruje hook její finální text do schránky. Kopíruje jen při zapnutém Auto Copy i přepínači \(target.displayName) a nikdy ne texty obsahující hesla, tokeny nebo soukromé klíče.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    row(target == .claude ? "Nastavení" : "Soubor hooků", controller.settingsPath, mono: true)
                    row("Hook Stop", hook.isRegistered ? "zaregistrován" : "není zaregistrován",
                        color: hook.isRegistered ? Theme.accent : Theme.secondaryText)
                    row("Pomocný program", helperText(hook), color: helperColor(hook))
                    if hook.otherStopHandlers > 0 {
                        row("Jiné Stop hooky", "\(hook.otherStopHandlers) – zůstanou beze změny")
                    }
                    row("Poslední událost", eventText)
                }

                if target == .codex {
                    notice(
                        hook.isRegistered && controller.event == nil
                            ? "Codex spustí nový hook až po schválení: v Codexu zadejte /hooks a hook potvrďte. Do té doby se přeskakuje."
                            : "Nový nebo změněný hook musí v Codexu schválit uživatel (/hooks). Existující notifikace v config.toml zůstávají beze změny. Codex Desktop zatím nebyl ověřen.",
                        color: Theme.warning, icon: "info.circle.fill"
                    )
                }
                if hook.hooksDisabled {
                    notice("V nastavení je hooky vypnuty (disableAllHooks = true), hooky se nespouštějí.", color: Theme.warning)
                }
                ForEach(hook.notes, id: \.self) { notice($0, color: Theme.warning) }
                if let problem = hook.settingsProblem { notice(problem, color: Theme.danger) }
                if let error = controller.error { notice(error, color: Theme.danger) }
                if let message = controller.notice { notice(message, color: Theme.accent, icon: "checkmark.circle.fill") }
                if let result = controller.testResult { notice(result, color: Theme.accent, icon: "checkmark.seal.fill") }

                HStack(spacing: 8) {
                    Button {
                        plan = controller.installPlan()
                        confirmInstall = true
                    } label: {
                        Label(hook.isRegistered ? "Aktualizovat hook" : "Nainstalovat hook", systemImage: "square.and.arrow.down")
                    }
                    .disabled(controller.bundledHelper == nil || (hook.isRegistered && hook.helperInstalled && hook.helperMatchesBundled != false))
                    if hook.isRegistered || hook.helperInstalled {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label("Odebrat hook", systemImage: "trash")
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button { controller.runTest(writeToClipboard: false) } label: {
                        Label("Otestovat (bez zápisu)", systemImage: "checkmark.seal")
                    }
                    Button { confirmRealTest = true } label: {
                        Label("Test se schránkou…", systemImage: "doc.on.clipboard")
                    }
                }
                Text("Vypnutí přepínačů hook neodstraňuje; ten pak jen okamžitě skončí a schránku nezmění. Při souběhu více agentů drží schránku ten, kdo kopíroval první: jiná relace ji během 5 sekund nepřepíše.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Nainstalovat hook do \(target.displayName)?", isPresented: $confirmInstall) {
            Button("Nainstalovat") { controller.install() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(plan.joined(separator: "\n"))
        }
        .confirmationDialog("Odebrat hook z \(target.displayName)?", isPresented: $confirmRemove) {
            Button("Odebrat", role: .destructive) { controller.remove() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Odstraní se pouze záznam Pure Clipboard z hooks.Stop (po záloze souboru). Ostatní hooky zůstanou; pomocný program se smaže jen pokud ho nepoužívá druhá integrace.")
        }
        .confirmationDialog("Přepsat schránku ukázkovým textem?", isPresented: $confirmRealTest) {
            Button("Přepsat schránku") { controller.runTest(writeToClipboard: true) }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Test zkopíruje neškodný ukázkový text a tím nahradí aktuální obsah schránky.")
        }
    }

    private func statusPill(_ hook: ClaudeHookState) -> some View {
        if hook.settingsProblem != nil { return StatusPill(text: "Nelze ověřit", color: Theme.danger) }
        if !hook.isRegistered { return StatusPill(text: "Nenainstalováno", color: Theme.warning) }
        if !hook.helperInstalled { return StatusPill(text: "Chybí pomocný program", color: Theme.danger) }
        if hook.hooksDisabled { return StatusPill(text: "Hooky vypnuty", color: Theme.warning) }
        if hook.helperMatchesBundled == false { return StatusPill(text: "Doporučena aktualizace", color: Theme.warning) }
        if target == .codex && controller.event == nil { return StatusPill(text: "Čeká na schválení v Codexu", color: Theme.warning) }
        return StatusPill(text: "Nainstalováno", color: Theme.accent)
    }

    private func helperText(_ hook: ClaudeHookState) -> String {
        guard hook.helperInstalled else { return "není nainstalován" }
        switch hook.helperMatchesBundled {
        case .some(true): return "aktuální"
        case .some(false): return "starší než verze v aplikaci"
        case .none: return "nainstalován"
        }
    }

    private func helperColor(_ hook: ClaudeHookState) -> Color {
        guard hook.helperInstalled else { return Theme.secondaryText }
        return hook.helperMatchesBundled == false ? Theme.warning : Theme.primaryText
    }

    private var eventText: String {
        guard let event = controller.event else { return "zatím žádná" }
        let time = event.timestamp.formatted(date: .abbreviated, time: .standard)
        if event.result == "copied" { return "\(time) · zkopírováno (\(event.characters) znaků)" }
        var text = "\(time) · přeskočeno: \(HookReasonLabel.text(event.reason))"
        if !event.findings.isEmpty { text += " (\(event.findings.joined(separator: ", ")))" }
        return text
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.primaryText, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func notice(_ message: String, color: Color, icon: String = "exclamationmark.triangle.fill") -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
