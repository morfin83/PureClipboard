import AppKit
import PureClipboardCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var section: StudioSection = .clipboard

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    HeaderView()
                    StudioNavigation(section: $section)
                    if let config = model.config {
                        if section == .clipboard {
                            PreviewNotice()
                            AutoCopyCard(config: config)
                            IntegrationsCard(config: config)
                            HStack(alignment: .top, spacing: 16) {
                                HistoryCard(config: config)
                                SensitiveDataCard(config: config)
                            }
                            HookCard(target: .claude)
                            HookCard(target: .codex)
                            TerminalCard()
                            ConfigStatusCard()
                        } else {
                            RemoteCard(enabled: config.integrations.pureRemote.enabled)
                        }
                    }
                    Text(section == .clipboard
                         ? "Pure Clipboard · Kopírování řídíte vy"
                         : "Pure Remote · Stav Tailscale se čte jen při zapnutém přepínači")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 24)
            }
        }
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshHooks()
        }
    }
}

private enum StudioSection: String, CaseIterable {
    case clipboard, remote

    var title: String { self == .clipboard ? "Pure Clipboard" : "Pure Remote" }
    var symbol: String { self == .clipboard ? "doc.on.clipboard" : "network" }
}

private struct StudioNavigation: View {
    @Binding var section: StudioSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StudioSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(section == item ? Theme.primaryText : Theme.secondaryText)
                        .background(section == item ? Theme.accent.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studioSection.\(item.rawValue)")
            }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
    }
}

private struct HeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Pure Clipboard")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.primaryText)
                Text("PURESTUDIO")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }
            Spacer()
            switch model.state {
            case .loading: StatusPill(text: "Načítání", color: Theme.secondaryText)
            case .loaded: StatusPill(text: "Konfigurace načtena", color: Theme.accent)
            case .missing: StatusPill(text: "Konfigurace chybí", color: Theme.warning)
            case .failed: StatusPill(text: "Chyba konfigurace", color: Theme.danger)
            }
        }
    }
}

private struct PreviewNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.warning)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude Code, Codex a Apple Terminal jsou připravené")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Označený text zkopírujete pomocí ⌘C, celou odpověď tlačítkem Kopírovat v AI aplikaci. Claude Code a Codex kopírují samy jen při zapnutém Auto Copy; Apple Terminal používá výslovný příkaz pclip.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.25)))
    }
}

private struct AutoCopyCard: View {
    @Environment(AppModel.self) private var model
    let config: PureClipboardConfig

    var body: some View {
        Card(title: "Automatické kopírování", symbol: "power") {
            HStack(spacing: 14) {
                IconTile(symbol: "doc.on.doc", active: config.global.autoCopy)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto Copy")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(config.global.autoCopy
                         ? "Zapnuto – Claude Code a Codex kopírují po dokončení odpovědi"
                         : "Vypnuto – agenti sami nekopírují; ruční kopírování funguje dál")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Toggle("Auto Copy", isOn: Binding(
                    get: { config.global.autoCopy },
                    set: { value in model.update { $0.global.autoCopy = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .accessibilityIdentifier("autoCopyToggle")
            }
        }
    }
}

struct IntegrationsCard: View {
    @Environment(AppModel.self) var model
    let config: PureClipboardConfig

    var body: some View {
        Card(title: "Integrace", symbol: "puzzlepiece.extension") {
            VStack(spacing: 0) {
                ForEach(Array([IntegrationID.terminal, .claudeCode, .codex].enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().overlay(Theme.cardBorder) }
                    IntegrationRow(id: id, settings: config.integrations[id], masterOn: config.global.autoCopy, trailing: trailing(for: id)) { value in
                        model.update { $0.integrations[id].enabled = value }
                    }
                }
            }
        }
    }
}

extension IntegrationsCard {
    func trailing(for id: IntegrationID) -> String {
        let target: HookTarget
        switch id {
        case .claudeCode: target = .claude
        case .codex: target = .codex
        case .terminal: return model.terminal.state.isInstalled ? "Příkaz pclip nainstalován" : "Příkaz pclip nenainstalován"
        default: return "Neaktivní"
        }
        let hook = model.controller(for: target).state
        if !hook.isRegistered { return "Hook nenainstalován" }
        if hook.hooksDisabled { return "Hooky vypnuty v Claude" }
        return "Hook nainstalován"
    }
}

private struct IntegrationRow: View {
    let id: IntegrationID
    let settings: IntegrationSettings
    let masterOn: Bool
    let trailing: String
    let onChange: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: id.symbolName, active: settings.enabled)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(id.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(IntegrationMode.label(for: settings.mode) ?? settings.mode)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.10), in: Capsule())
                }
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Text(trailing)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(trailing.hasSuffix(" nainstalován") && !trailing.contains("nenainstalován") ? Theme.accent : Theme.tertiaryText)
            Toggle(id.displayName, isOn: Binding(get: { settings.enabled }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("integrationToggle.\(id.rawValue)")
        }
        .padding(.vertical, 10)
    }

    private var statusText: String {
        if !settings.enabled { return "\(id.summary) · vypnuto" }
        if id == .terminal { return "\(id.summary) · na příkaz pclip" }
        return masterOn ? "\(id.summary) · povoleno v konfiguraci" : "\(id.summary) · čeká na Auto Copy"
    }
}

private struct HistoryCard: View {
    @Environment(AppModel.self) private var model
    let config: PureClipboardConfig

    var body: some View {
        Card(title: "Historie schránky · připravuje se", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(config.global.historyLimit)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                    Text("položek")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Stepper("Limit historie", value: Binding(
                        get: { config.global.historyLimit },
                        set: { value in model.update { $0.global.historyLimit = value } }
                    ), in: PureClipboardConfig.historyLimitRange)
                    .labelsHidden()
                }
                HStack(spacing: 6) {
                    ForEach([10, 20, 50, 100], id: \.self) { preset in
                        Button("\(preset)") { model.update { $0.global.historyLimit = preset } }
                            .buttonStyle(PresetButtonStyle(selected: config.global.historyLimit == preset))
                    }
                }
                Text("Nastavený limit pro budoucí historii (\(PureClipboardConfig.historyLimitRange.lowerBound)–\(PureClipboardConfig.historyLimitRange.upperBound)). Obsah schránky se zatím neukládá.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Theme.accent : Color.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
    }
}

private struct SensitiveDataCard: View {
    @Environment(AppModel.self) private var model
    let config: PureClipboardConfig
    @State private var confirmDisable = false

    var body: some View {
        let protected = config.global.protectSensitiveData
        Card(title: "Ochrana citlivých údajů", symbol: "lock.shield") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: protected ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(protected ? Theme.accent : Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(protected ? "Aktivní" : "Vypnuto")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(protected ? "Hooky a pclip nezkopírují rozpoznaná hesla a tokeny" : "Doporučujeme ochranu zapnout")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Toggle("Ochrana citlivých údajů", isOn: Binding(
                        get: { protected },
                        set: { value in
                            if value { model.update { $0.global.protectSensitiveData = true } } else { confirmDisable = true }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                Text("Ochrana platí pro hooky a pclip. Ruční kopírování v jiných aplikacích řídí macOS.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Vypnout ochranu citlivých údajů?", isPresented: $confirmDisable) {
            Button("Vypnout ochranu", role: .destructive) {
                model.update { $0.global.protectSensitiveData = false }
            }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Bez ochrany mohou hooky nebo pclip zkopírovat hesla a tokeny.")
        }
    }
}

private struct ConfigStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Konfigurace", symbol: "doc.badge.gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                row("Soubor", model.configPath, mono: true)
                row("Stav", stateText, color: stateColor)
                if let permissions = model.permissions {
                    row("Oprávnění", String(format: "%04o", permissions) + (permissions == 0o600 ? "  ✓" : "  (při uložení se nastaví 0600)"),
                        color: permissions == 0o600 ? Theme.accent : Theme.warning, mono: true)
                }
                if let lastSaved = model.lastSaved {
                    row("Uloženo", lastSaved.formatted(date: .omitted, time: .standard))
                } else if let lastLoaded = model.lastLoaded {
                    row("Načteno", lastLoaded.formatted(date: .omitted, time: .standard))
                }

                if case .failed(let error) = model.state {
                    errorBox(error.localizedDescription + " Soubor nebyl změněn.")
                }
                if let error = model.saveError {
                    errorBox(error.localizedDescription)
                }

                HStack(spacing: 8) {
                    Button { model.reload() } label: { Label("Znovu načíst", systemImage: "arrow.clockwise") }
                    if model.state != .missing {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) } label: {
                            Label("Zobrazit ve Finderu", systemImage: "folder")
                        }
                    } else {
                        Button { model.createDefaultConfig() } label: { Label("Vytvořit výchozí konfiguraci", systemImage: "plus") }
                    }
                }
                .controlSize(.regular)
                .padding(.top, 2)
            }
        }
    }

    private var stateText: String {
        switch model.state {
        case .loading: "Načítání…"
        case .loaded: "Načteno a ověřeno"
        case .missing: "Soubor neexistuje"
        case .failed: "Načtení selhalo – úpravy jsou zablokované"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .loaded: Theme.accent
        case .missing: Theme.warning
        case .failed: Theme.danger
        case .loading: Theme.secondaryText
        }
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.primaryText, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
