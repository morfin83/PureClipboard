import AppKit
import Observation
import PureClipboardCore
import SwiftUI

/// Stav rychlé historie sdílený mezi AppKit ovládáním a SwiftUI seznamem.
@MainActor
@Observable
final class QuickHistoryState {
    var picker = QuickPickerModel()
    var historyEnabled = false
}

/// Malý plovoucí panel. Může být klíčový, aby pole pro hledání přijímalo psaní, ale nikdy se nevkládá do aplikací.
@MainActor
final class QuickHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Směruje klávesy z pole pro hledání: šipky vybírají, Enter kopíruje, Esc zavře.
@MainActor
final class QuickHistorySearchDelegate: NSObject, NSTextFieldDelegate {
    private let state: QuickHistoryState
    var onChoose: () -> Void = {}
    var onClose: () -> Void = {}

    init(state: QuickHistoryState) {
        self.state = state
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        state.picker.setQuery(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            state.picker.moveUp()
        case #selector(NSResponder.moveDown(_:)):
            state.picker.moveDown()
        case #selector(NSResponder.insertNewline(_:)):
            onChoose()
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
        default:
            return false
        }
        return true
    }
}

/// Řídí zkratku ⌥⌘V a panel. Otevření jen čte uloženou historii; nic nezačíná sledovat.
@MainActor
final class QuickHistoryController {
    private let history: HistoryController
    private let state = QuickHistoryState()
    private lazy var searchDelegate = QuickHistorySearchDelegate(state: state)
    private var panel: QuickHistoryPanel?
    private weak var searchField: NSTextField?
    private var hotKey: GlobalHotKey?

    init(history: HistoryController) {
        self.history = history
        searchDelegate.onChoose = { [weak self] in self?.chooseSelected() }
        searchDelegate.onClose = { [weak self] in self?.close() }
    }

    /// Zaregistruje systémovou zkratku. Volá se jen za běhu aplikace.
    func startShortcut() {
        guard hotKey == nil else { return }
        let key = GlobalHotKey.quickHistory { [weak self] in self?.toggle() }
        if key.register() {
            hotKey = key
        } else {
            NSLog("Pure Clipboard: zkratku ⌥⌘V se nepodařilo zaregistrovat, pravděpodobně ji používá jiná aplikace.")
        }
    }

    /// Uvolní zkratku a zavře panel. Volá se při ukončení aplikace.
    func stopShortcut() {
        hotKey?.unregister()
        hotKey = nil
        close()
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        history.refresh()
        state.historyEnabled = history.settings.enabled
        state.picker.setItems(state.historyEnabled ? history.items : [])
        state.picker.setQuery("")

        let panel = panel ?? makePanel()
        self.panel = panel
        searchField?.stringValue = ""
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY + area.height / 6))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if let searchField {
            panel.makeFirstResponder(searchField)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func chooseSelected() {
        guard let item = state.picker.selected else { return }
        history.restore(item)
        close()
    }

    private func makePanel() -> QuickHistoryPanel {
        let panel = QuickHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let field = NSTextField()
        field.placeholderString = "Hledat v historii"
        field.setAccessibilityLabel("Hledat v rychlé historii")
        field.delegate = searchDelegate
        field.translatesAutoresizingMaskIntoConstraints = false
        searchField = field

        let list = NSHostingView(rootView: QuickHistoryListView(state: state, onChoose: { [weak self] in
            self?.chooseSelected()
        }).preferredColorScheme(.dark))
        list.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(field)
        content.addSubview(list)
        panel.contentView = content

        let guide = panel.contentLayoutGuide as? NSLayoutGuide
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: guide?.topAnchor ?? content.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        return panel
    }
}

/// Seznam posledních položek. Vybraná položka je zvýrazněna a posouvá se do zobrazení.
struct QuickHistoryListView: View {
    let state: QuickHistoryState
    let onChoose: () -> Void

    var body: some View {
        Group {
            if !state.historyEnabled {
                QuickEmptyText(text: "Historie je vypnutá. Zapněte ji v záložce Historie.")
            } else if state.picker.isEmpty {
                QuickEmptyText(text: state.picker.query.isEmpty ? "Historie je zatím prázdná." : "Nic neodpovídá hledání.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(state.picker.visible.enumerated()), id: \.element.id) { index, item in
                                QuickHistoryRow(item: item, selected: index == state.picker.selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        state.picker.select(index)
                                        onChoose()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: state.picker.selectedIndex) { _, newValue in
                        guard state.picker.visible.indices.contains(newValue) else { return }
                        proxy.scrollTo(state.picker.visible[newValue].id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder))
    }
}

private struct QuickEmptyText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickHistoryRow: View {
    let item: HistoryItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.isEmpty ? item.kind.label : item.preview)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.white.opacity(0.10) : Color.clear))
    }

    private var meta: String {
        var parts = [item.kind.label, item.createdAt.formatted(.relative(presentation: .named))]
        if let app = item.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}
