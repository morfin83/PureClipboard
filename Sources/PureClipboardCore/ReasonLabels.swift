import Foundation

public enum HookReasonLabel {
    public static func text(_ reason: String) -> String {
        switch reason {
        case "auto-copy-off": "Auto Copy je vypnutý"
        case "integration-off": "přepínač integrace je vypnutý"
        case "config-unavailable": "konfiguraci nelze načíst nebo je neplatná"
        case "sensitive-content": "podezření na citlivé údaje"
        case "no-final-message": "událost neobsahuje finální odpověď"
        case "empty-message": "prázdná odpověď"
        case "message-too-large", "payload-too-large": "příliš velký text"
        case "unexpected-event": "jiná událost než Stop"
        case "invalid-payload": "neplatná data události"
        case "clipboard-write-failed": "zápis do schránky selhal"
        case "recent-copy-by-other-session": "jiná relace právě kopírovala (ochrana před přepsáním)"
        case "lock-unavailable": "schránku právě používá jiný hook"
        case "no-output": "příkaz nevypsal žádný výstup"
        case "invalid-device": "neplatný název zařízení"
        case "nothing-to-fetch": "není co stáhnout"
        case "mailbox-write-failed": "poštu se nepodařilo uložit"
        default: reason
        }
    }
}
