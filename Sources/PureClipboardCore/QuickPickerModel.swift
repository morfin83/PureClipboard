import Foundation

/// Výběr v rychlé historii (⌥⌘V): filtr přes `HistorySearch`, ořezaný seznam a index vybrané položky.
/// Čistý model bez AppKit, takže jde otestovat bez spuštěné aplikace.
public struct QuickPickerModel: Equatable, Sendable {
    public static let defaultLimit = 50

    /// Nejvýše tolik položek se zobrazí, i když jich odpovídá víc.
    public let limit: Int
    public private(set) var query: String
    /// Položky, které odpovídají dotazu, nejnovější první, ořezané na `limit`.
    public private(set) var visible: [HistoryItem]
    /// Index vybrané položky v `visible`. Vždy v rozsahu, je-li něco zobrazeno; jinak 0.
    public private(set) var selectedIndex: Int

    private var source: [HistoryItem]

    public init(items: [HistoryItem] = [], query: String = "", limit: Int = QuickPickerModel.defaultLimit) {
        self.limit = max(1, limit)
        self.query = query
        self.source = items
        self.visible = []
        self.selectedIndex = 0
        recompute(keepSelection: false)
    }

    public var selected: HistoryItem? {
        visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil
    }

    public var isEmpty: Bool { visible.isEmpty }

    /// Nahradí zdrojové položky (např. po obnovení historie). Výběr zůstane na stejné položce, pokud je pořád vidět.
    public mutating func setItems(_ items: [HistoryItem]) {
        source = items
        recompute(keepSelection: true)
    }

    /// Nastaví hledání. Výběr se vrací na první odpovídající položku.
    public mutating func setQuery(_ query: String) {
        self.query = query
        recompute(keepSelection: false)
    }

    /// Posun výběru o jednu položku nahoru. Na začátku zůstává.
    public mutating func moveUp() {
        select(selectedIndex - 1)
    }

    /// Posun výběru o jednu položku dolů. Na konci zůstává.
    public mutating func moveDown() {
        select(selectedIndex + 1)
    }

    /// Vybere položku na indexu; hodnota mimo rozsah se ořízne na nejbližší platnou.
    public mutating func select(_ index: Int) {
        guard !visible.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(index, 0), visible.count - 1)
    }

    private mutating func recompute(keepSelection: Bool) {
        let previousID = keepSelection ? selected?.id : nil
        visible = Array(HistorySearch.filter(source, query: query).prefix(limit))
        if let previousID, let index = visible.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = index
        } else {
            select(keepSelection ? selectedIndex : 0)
        }
    }
}
