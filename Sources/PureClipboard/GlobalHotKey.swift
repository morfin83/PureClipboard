import Carbon.HIToolbox
import Foundation

/// Systémová klávesová zkratka přes Carbon `RegisterEventHotKey`.
///
/// Na rozdíl od event tapu nečte stisky kláves: systém doručí jen zaregistrovanou kombinaci
/// a nic jiného aplikace nevidí. Zkratka běží, dokud je aplikace spuštěná; `unregister()` ji uvolní.
@MainActor
final class GlobalHotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    /// Vrátí `false`, pokud systém zkratku nepřijal (např. ji už používá jiná aplikace).
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard readStatus == noErr, identifier.signature == quickHistoryHotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let pointer = userData
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().action()
                }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard installStatus == noErr else {
            handlerRef = nil
            return false
        }

        let identifier = EventHotKeyID(signature: quickHistoryHotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr, hotKeyRef != nil else {
            unregister()
            return false
        }
        return true
    }

    /// Uvolní zkratku i obslužnou rutinu. Bezpečné volat opakovaně.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        hotKeyRef = nil
        handlerRef = nil
    }
}

private func fourCharCode(_ text: String) -> OSType {
    text.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}

/// Podpis zkratky v EventHotKeyID. Je mimo třídu, aby šel čist z C callbacku bez izolace MainActor.
private let quickHistoryHotKeySignature = fourCharCode("PCQH")

/// Výchozí zkratka rychlé historie: ⌥⌘V.
extension GlobalHotKey {
    static func quickHistory(action: @escaping @MainActor () -> Void) -> GlobalHotKey {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey), action: action)
    }
}
