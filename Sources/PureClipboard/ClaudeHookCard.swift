import PureClipboardCore
import SwiftUI

struct ClaudeHookCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmInstall = false
    @State private var confirmRemove = false
    @State private var plan: [String] = []

    var body: some View {
        let hook = model.hookState
        Card(title: "Claude Code – hook", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    statusPill(hook)
                    Spacer()
                }
                Text("Po dokončení odpovědi Claude Code zkopíruje hook její finální text do schránky. Kopíruje jen při zapnutém Auto Copy i Claude Code a nikdy ne texty obsahující hesla, tokeny nebo soukromé klíče.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    row("Nastavení", model.settingsPath, mono: true)
                    row("Hook Stop", hook.isRegistered ? "zaregistrován" : "není zaregistrován",
                        color: hook.isRegistered ? Theme.accent : Theme.secondaryText)
                    row("Pomocný program", helperText(hook), color: helperColor(hook))
                    if hook.otherStopHandlers > 0 {
                        row("Jiné Stop hooky", "\(hook.otherStopHandlers) – zůstanou beze změny")
                    }
                    row("Poslední událost", eventText)
                }

                if hook.hooksDisabled {
                    notice("V nastavení Claude Code je disableAllHooks = true, hooky se nespouštějí.", color: Theme.warning)
                }
                if let problem = hook.settingsProblem {
                    notice(problem, color: Theme.danger)
                }
                if let error = model.hookError {
                    notice(error, color: Theme.danger)
                }
                if let message = model.hookNotice {
                    notice(message, color: Theme.accent)
                }

                HStack(spacing: 8) {
                    Button {
                        plan = model.hookInstallPlan()
                        confirmInstall = true
                    } label: {
                        Label(hook.isRegistered ? "Aktualizovat hook" : "Nainstalovat hook", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.bundledHelper == nil || (hook.isRegistered && hook.helperInstalled && hook.helperMatchesBundled != false))
                    if hook.isRegistered || hook.helperInstalled {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label("Odebrat hook", systemImage: "trash")
                        }
                    }
                }
                Text("Vypnutí přepínačů hook neodstraňuje; ten pak jen okamžitě skončí a schránku nezmění. Úplné odebrání provedete tlačítkem výše.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Nainstalovat hook do Claude Code?", isPresented: $confirmInstall) {
            Button("Nainstalovat") { model.installHook() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(plan.joined(separator: "\n"))
        }
        .confirmationDialog("Odebrat hook z Claude Code?", isPresented: $confirmRemove) {
            Button("Odebrat", role: .destructive) { model.removeHook() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Odstraní se pouze záznam Pure Clipboard z hooks.Stop (po záloze nastavení) a pomocný program. Ostatní hooky zůstanou.")
        }
    }

    private func statusPill(_ hook: ClaudeHookState) -> some View {
        if hook.settingsProblem != nil { return StatusPill(text: "Nelze ověřit", color: Theme.danger) }
        if !hook.isRegistered { return StatusPill(text: "Nenainstalováno", color: Theme.warning) }
        if !hook.helperInstalled { return StatusPill(text: "Chybí pomocný program", color: Theme.danger) }
        if hook.hooksDisabled { return StatusPill(text: "Hooky vypnuty", color: Theme.warning) }
        if hook.helperMatchesBundled == false { return StatusPill(text: "Doporučena aktualizace", color: Theme.warning) }
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
        guard let event = model.hookEvent else { return "zatím žádná" }
        let time = event.timestamp.formatted(date: .abbreviated, time: .standard)
        if event.result == "copied" { return "\(time) · zkopírováno (\(event.characters) znaků)" }
        var text = "\(time) · přeskočeno: \(Self.reasonLabel(event.reason))"
        if !event.findings.isEmpty { text += " (\(event.findings.joined(separator: ", ")))" }
        return text
    }

    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "sensitive-content": "podezření na citlivé údaje"
        case "no-final-message": "událost neobsahuje finální odpověď"
        case "empty-message": "prázdná odpověď"
        case "message-too-large", "payload-too-large": "příliš velký text"
        case "unexpected-event": "jiná událost než Stop"
        case "invalid-payload": "neplatná data události"
        case "clipboard-write-failed": "zápis do schránky selhal"
        default: reason
        }
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

    private func notice(_ message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: color == Theme.accent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
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
