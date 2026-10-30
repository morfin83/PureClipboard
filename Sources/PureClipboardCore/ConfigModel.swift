import Foundation

public struct PureClipboardConfig: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    public static let historyLimitRange = 1...500

    public var schemaVersion: Int
    public var global: GlobalSettings
    public var integrations: Integrations

    public static let defaults = PureClipboardConfig(
        schemaVersion: supportedSchemaVersion,
        global: GlobalSettings(autoCopy: false, historyLimit: 20, protectSensitiveData: true),
        integrations: Integrations(
            terminal: IntegrationSettings(enabled: false, mode: "diagnostics"),
            claudeCode: IntegrationSettings(enabled: false, mode: "finalResponse"),
            codex: IntegrationSettings(enabled: false, mode: "finalResponse"),
            pureRemote: IntegrationSettings(enabled: false, mode: "actionResults"),
            termux: IntegrationSettings(enabled: false, mode: "localClipboard")
        )
    )

    /// Human-readable list of problems; empty when the configuration is valid.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        if schemaVersion != Self.supportedSchemaVersion {
            issues.append("Nepodporovaná verze schématu \(schemaVersion) (podporováno: \(Self.supportedSchemaVersion)).")
        }
        if !Self.historyLimitRange.contains(global.historyLimit) {
            issues.append("global.historyLimit musí být v rozsahu \(Self.historyLimitRange.lowerBound)–\(Self.historyLimitRange.upperBound), nalezeno \(global.historyLimit).")
        }
        for id in IntegrationID.allCases {
            let mode = integrations[id].mode
            let valid = !mode.isEmpty && mode.count <= 64
                && mode.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            if !valid {
                issues.append("integrations.\(id.rawValue).mode má neplatnou hodnotu „\(mode)“.")
            }
        }
        return issues
    }
}

public struct GlobalSettings: Codable, Equatable, Sendable {
    public var autoCopy: Bool
    public var historyLimit: Int
    public var protectSensitiveData: Bool
}

public struct IntegrationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mode: String
}

public struct Integrations: Codable, Equatable, Sendable {
    public var terminal: IntegrationSettings
    public var claudeCode: IntegrationSettings
    public var codex: IntegrationSettings
    public var pureRemote: IntegrationSettings
    public var termux: IntegrationSettings

    public subscript(id: IntegrationID) -> IntegrationSettings {
        get { self[keyPath: id.keyPath] }
        set { self[keyPath: id.keyPath] = newValue }
    }
}

public enum IntegrationID: String, CaseIterable, Identifiable, Sendable {
    case terminal, claudeCode, codex, pureRemote, termux

    public var id: String { rawValue }

    var keyPath: WritableKeyPath<Integrations, IntegrationSettings> {
        switch self {
        case .terminal: \.terminal
        case .claudeCode: \.claudeCode
        case .codex: \.codex
        case .pureRemote: \.pureRemote
        case .termux: \.termux
        }
    }

    public var displayName: String {
        switch self {
        case .terminal: "Apple Terminal"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pureRemote: "Pure Remote"
        case .termux: "Termux"
        }
    }

    public var symbolName: String {
        switch self {
        case .terminal: "apple.terminal"
        case .claudeCode: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .pureRemote: "antenna.radiowaves.left.and.right"
        case .termux: "candybarphone"
        }
    }

    public var summary: String {
        switch self {
        case .terminal: "Výstup příkazů z Terminal.app"
        case .claudeCode: "Odpovědi z relací Claude Code"
        case .codex: "Odpovědi z Codex CLI"
        case .pureRemote: "Provoz zařízení v Tailscale"
        case .termux: "Schránka zařízení s Termuxem"
        }
    }
}

public enum IntegrationMode {
    public static func label(for mode: String) -> String? {
        switch mode {
        case "diagnostics": "Diagnostika"
        case "finalResponse": "Finální odpověď"
        case "actionResults": "Živý přehled"
        case "localClipboard": "Lokální schránka"
        default: nil
        }
    }
}
