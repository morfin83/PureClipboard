import Foundation
import Testing
@testable import PureClipboardCore

private func item(_ text: String, id: UUID = UUID(), app: String? = nil) -> HistoryItem {
    HistoryItem(
        id: id, createdAt: Date(timeIntervalSince1970: 0), kind: .text, preview: text,
        searchText: HistorySearch.fold(text), byteSize: text.utf8.count, contentHash: text,
        sourceApp: app, blobs: [:], files: nil, screening: "text-scan"
    )
}

@Suite("Rychlá historie – výběr")
struct QuickPickerModelTests {
    @Test("Bez položek nic nevybírá")
    func emptyModel() {
        var model = QuickPickerModel()
        #expect(model.isEmpty)
        #expect(model.selected == nil)
        model.moveDown()
        model.moveUp()
        #expect(model.selectedIndex == 0)
        #expect(model.selected == nil)
    }

    @Test("Výchozí výběr je první položka")
    func defaultSelection() {
        let model = QuickPickerModel(items: [item("a"), item("b")])
        #expect(model.visible.count == 2)
        #expect(model.selectedIndex == 0)
        #expect(model.selected?.preview == "a")
    }

    @Test("Šipky se na krajích zastaví, nepřetečou")
    func movementClamps() {
        var model = QuickPickerModel(items: [item("a"), item("b"), item("c")])
        model.moveUp()
        #expect(model.selectedIndex == 0)
        model.moveDown()
        model.moveDown()
        model.moveDown()
        model.moveDown()
        #expect(model.selectedIndex == 2)
        #expect(model.selected?.preview == "c")
        model.moveUp()
        #expect(model.selected?.preview == "b")
    }

    @Test("Výběr mimo rozsah se ořízne")
    func selectClamps() {
        var model = QuickPickerModel(items: [item("a"), item("b")])
        model.select(99)
        #expect(model.selectedIndex == 1)
        model.select(-5)
        #expect(model.selectedIndex == 0)
    }

    @Test("Hledání filtruje přes HistorySearch a vrací výběr na začátek")
    func searchFilters() {
        var model = QuickPickerModel(items: [item("Ahoj světe"), item("Nákup mléko"), item("ahoj znovu")])
        model.moveDown()
        model.setQuery("AHOJ")
        #expect(model.visible.map(\.preview) == ["Ahoj světe", "ahoj znovu"])
        #expect(model.selectedIndex == 0)
        model.setQuery("mleko")
        #expect(model.visible.map(\.preview) == ["Nákup mléko"])
    }

    @Test("Diakritika v hledání nevadí")
    func diacriticsIgnored() {
        let model = QuickPickerModel(items: [item("Nákup"), item("Jiné")], query: "nakup")
        #expect(model.visible.map(\.preview) == ["Nákup"])
    }

    @Test("Bez shody je seznam prázdný a výběr nil")
    func noMatch() {
        var model = QuickPickerModel(items: [item("a")])
        model.setQuery("zzz")
        #expect(model.isEmpty)
        #expect(model.selected == nil)
        model.moveDown()
        #expect(model.selectedIndex == 0)
    }

    @Test("Seznam se ořízne na limit")
    func limitApplied() {
        let items = (0..<120).map { item("položka \($0)") }
        let model = QuickPickerModel(items: items, limit: 10)
        #expect(model.visible.count == 10)
        #expect(model.visible.first?.preview == "položka 0")
    }

    @Test("Výchozí limit je 50 a limit nejde nastavit pod 1")
    func limitDefaults() {
        let items = (0..<60).map { item("x\($0)") }
        #expect(QuickPickerModel(items: items).visible.count == QuickPickerModel.defaultLimit)
        #expect(QuickPickerModel(items: items, limit: 0).limit == 1)
    }

    @Test("Při obnovení položek zůstane výběr na stejné položce")
    func setItemsKeepsSelection() {
        let a = item("a"), b = item("b"), c = item("c")
        var model = QuickPickerModel(items: [a, b, c])
        model.select(1)
        model.setItems([c, b])
        #expect(model.selected?.id == b.id)
        #expect(model.selectedIndex == 1)
    }

    @Test("Když vybraná položka zmizí, výběr se ořízne do rozsahu")
    func setItemsClampsWhenSelectionGone() {
        let a = item("a"), b = item("b"), c = item("c")
        var model = QuickPickerModel(items: [a, b, c])
        model.select(2)
        model.setItems([a])
        #expect(model.selectedIndex == 0)
        #expect(model.selected?.id == a.id)
        model.setItems([])
        #expect(model.selectedIndex == 0)
        #expect(model.selected == nil)
    }
}
