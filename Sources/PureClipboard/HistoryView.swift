import AppKit
import PureClipboardCore
import SwiftUI

struct HistorySection: View {
    @Environment(AppModel.self) private var model
    let config: PureClipboardConfig

    var body: some View {
        let history = model.history
        VStack(spacing: 16) {
            HistorySwitchCard(settings: config.clipboardHistory)
            if let notice = history.notice {
                HStack(alignment: .top) {
                    NoticeBox(message: notice.text, color: notice.isError ? Theme.warning : Theme.accent,
                              icon: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Button { history.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("Zavřít zprávu")
                }
            }
            HistoryRulesCard(settings: config.clipboardHistory)
            HistoryListCard(settings: config.clipboardHistory)
        }
    }
}

private struct HistorySwitchCard: View {
    @Environment(AppModel.self) private var model
    let settings: ClipboardHistorySettings
    @State private var confirmEnable = false

    var body: some View {
        let history = model.history
        Card(title: "Historie systémové schránky", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    IconTile(symbol: "clock.arrow.circlepath", active: settings.isCapturing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ukládat historii schránky")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(stateText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    StatusPill(text: pillText, color: pillColor)
                    Toggle("Ukládat historii schránky", isOn: Binding(
                        get: { settings.enabled },
                        set: { value in
                            if value { confirmEnable = true } else { model.update { $0.clipboardHistory.enabled = false } }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .disabled(!model.isEditable)
                    .accessibilityIdentifier("historyToggle")
                }
                if settings.enabled {
                    HStack(spacing: 8) {
                        Button {
                            model.update { $0.clipboardHistory.paused.toggle() }
                        } label: {
                            Label(settings.paused ? "Pokračovat" : "Pozastavit", systemImage: settings.paused ? "play.fill" : "pause.fill")
                        }
                        .accessibilityIdentifier("historyPause")
                        Text(captureSummary(history.status))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                        Spacer()
                    }
                } else {
                    NoticeBox(
                        message: "Historie je ve výchozím stavu vypnutá. Po zapnutí Pure Clipboard sleduje systémovou schránku, ale jen dokud je aplikace spuštěná, a ukládá kopie pouze na tento Mac. Nic se neposílá do cloudu.",
                        color: Theme.accent, icon: "info.circle.fill")
                }
            }
        }
        .confirmationDialog("Zapnout historii schránky?", isPresented: $confirmEnable) {
            Button("Zapnout historii") { model.update { $0.clipboardHistory.enabled = true; $0.clipboardHistory.paused = false } }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Pure Clipboard bude sledovat všechno, co v jiných aplikacích zkopírujete, a ukládat text, formátovaný text a odkazy na soubory. Obrázky a PDF se neukládají, dokud je zvlášť nepovolíte. Hesla a tokeny se přeskočí, ale spolehlivé rozpoznání nelze zaručit. Obsah můžete kdykoli smazat.")
        }
    }

    private var stateText: String {
        if !settings.enabled { return "Vypnuto – schránka se nesleduje a nic se neukládá" }
        if settings.paused { return "Pozastaveno – nové kopie se neukládají" }
        return "Zapnuto – sleduje se, dokud je aplikace spuštěná"
    }

    private var pillText: String { !settings.enabled ? "Vypnuto" : settings.paused ? "Pozastaveno" : "Sleduje" }
    private var pillColor: Color { !settings.enabled ? Theme.secondaryText : settings.paused ? Theme.warning : Theme.accent }

    private func captureSummary(_ status: HistoryMonitorStatus) -> String {
        var text = "V tomto běhu uloženo \(status.storedCount), přeskočeno \(status.skippedCount)"
        if let reason = status.lastSkipReason { text += " · naposledy: \(CaptureReasons.label(reason))" }
        return text
    }
}

private struct HistoryRulesCard: View {
    @Environment(AppModel.self) private var model
    let settings: ClipboardHistorySettings

    var body: some View {
        Card(title: "Pravidla ukládání", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                stepper("Nejvýše položek", value: settings.maxItems, range: ClipboardHistorySettings.maxItemsRange, step: 10, unit: "", id: "maxItems") { $0.maxItems = $1 }
                stepper("Nejdéle dnů", value: settings.maxAgeDays, range: ClipboardHistorySettings.maxAgeDaysRange, step: 1, unit: "dní", id: "maxAgeDays") { $0.maxAgeDays = $1 }
                stepper("Největší položka", value: settings.maxItemMegabytes, range: ClipboardHistorySettings.maxItemMegabytesRange, step: 1, unit: "MB", id: "maxItemMegabytes") { $0.maxItemMegabytes = $1 }
                stepper("Celé úložiště", value: settings.maxTotalMegabytes, range: ClipboardHistorySettings.maxTotalMegabytesRange, step: 10, unit: "MB", id: "maxTotalMegabytes") { $0.maxTotalMegabytes = $1 }
                Divider().overlay(Theme.cardBorder)
                consent("Ukládat obrázky", isOn: settings.storeImages, id: "storeImages") { $0.storeImages = $1 }
                consent("Ukládat PDF", isOn: settings.storePDF, id: "storePDF") { $0.storePDF = $1 }
                Text("Před uložením se obrázky a PDF prohlédnou rozpoznáváním textu přímo v Macu (OCR) a při nálezu hesla nebo tokenu se přeskočí. OCR ale nenajde všechno – rukopis, QR kódy, malé nebo nízkokontrastní písmo ani tajné údaje, které nejsou text. Povolte jen pokud tomu rozumíte. Soubory a složky z Finderu se ukládají jen jako odkazy na originály, ne jako kopie.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.saveError {
                    NoticeBox(message: error.localizedDescription, color: Theme.danger, icon: "xmark.octagon.fill")
                }
            }
        }
    }

    private func stepper(_ title: String, value: Int, range: ClosedRange<Int>, step: Int, unit: String, id: String,
                         set: @escaping (inout ClipboardHistorySettings, Int) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text("\(value)" + (unit.isEmpty ? "" : " \(unit)"))
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Theme.primaryText)
                .frame(minWidth: 80, alignment: .trailing)
            Stepper(title, value: Binding(
                get: { value },
                set: { new in model.update { set(&$0.clipboardHistory, new) } }
            ), in: range, step: step)
            .labelsHidden()
            .accessibilityIdentifier("history.\(id)")
        }
        .disabled(!model.isEditable)
    }

    private func consent(_ title: String, isOn: Bool, id: String, set: @escaping (inout ClipboardHistorySettings, Bool) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primaryText)
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: { new in model.update { set(&$0.clipboardHistory, new) } }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("history.\(id)")
        }
        .disabled(!model.isEditable)
    }
}

private struct HistoryListCard: View {
    @Environment(AppModel.self) private var model
    let settings: ClipboardHistorySettings
    @State private var confirmClear = false

    var body: some View {
        @Bindable var history = model.history
        let shown = history.filtered
        Card(title: "Uložené položky (\(history.items.count))", symbol: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                        TextField("Hledat v historii", text: $history.query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Hledat v historii")
                            .accessibilityIdentifier("historySearch")
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Button(role: .destructive) { confirmClear = true } label: { Label("Smazat vše", systemImage: "trash") }
                        .disabled(history.items.isEmpty)
                        .accessibilityIdentifier("historyClear")
                    Button { history.revealFolder() } label: { Image(systemName: "folder") }
                        .accessibilityLabel("Zobrazit složku historie ve Finderu")
                        .help("Zobrazit složku historie ve Finderu")
                }
                if history.items.isEmpty {
                    emptyState(settings.enabled ? "Zatím nic neuloženo. Zkopírujte něco v jiné aplikaci." : "Historie je prázdná. Zapněte ji výše.")
                } else if shown.isEmpty {
                    emptyState("Nic neodpovídá hledání.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { item in
                            HistoryRow(item: item)
                            if item.id != shown.last?.id { Divider().overlay(Theme.cardBorder) }
                        }
                    }
                }
                Text("Celkem \(ByteCountFormatter.string(fromByteCount: Int64(history.totalBytes), countStyle: .file)). Smazání odstraní soubory historie; na SSD nelze zaručit nevratné přepsání dat.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
        }
        .confirmationDialog("Smazat celou historii?", isPresented: $confirmClear) {
            Button("Smazat všech \(history.items.count) položek", role: .destructive) { history.clearAll() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Odstraní se všechny uložené položky. Odkazovaným souborům se nic nestane.")
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 22)
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let item: HistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: item.kind.symbolName)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview.isEmpty ? item.kind.label : item.preview)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.primaryText).lineLimit(3)
                Text(meta).font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText)
                if item.kind == .files, let files = item.files {
                    FileStatusList(files: files)
                }
            }
            Spacer(minLength: 8)
            Button { model.history.restore(item) } label: { Label("Vrátit do schránky", systemImage: "doc.on.clipboard") }
                .labelStyle(.iconOnly)
                .help("Vrátit do schránky")
                .accessibilityLabel("Vrátit do schránky: \(item.preview)")
            Button(role: .destructive) { model.history.delete(item) } label: { Image(systemName: "trash") }
                .help("Smazat položku")
                .accessibilityLabel("Smazat položku: \(item.preview)")
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private var meta: String {
        var parts = [item.kind.label, item.createdAt.formatted(.relative(presentation: .named))]
        if item.byteSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)) }
        if let app = item.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

private struct FileStatusList: View {
    let files: [HistoryFileRef]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(files.prefix(5).enumerated()), id: \.offset) { _, file in
                let status = file.resolve()
                HStack(spacing: 5) {
                    Image(systemName: file.isDirectory ? "folder" : "doc").font(.system(size: 9.5))
                    Text(file.name).lineLimit(1)
                    Text("· " + status.label).foregroundStyle(status == .available ? Theme.tertiaryText : Theme.warning).lineLimit(1)
                }
                .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
            }
            if files.count > 5 { Text("… a \(files.count - 5) dalších").font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText) }
        }
    }
}
