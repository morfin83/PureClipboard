import AppKit
import Darwin
import Foundation
import PureClipboardCore

struct PasteboardWriter: ClipboardWriting {
    func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        return pasteboard.string(forType: .string) == text
    }
}

func readStandardInput(limit: Int) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= limit {
        let count = read(0, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

func printLine(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

/// Hook entry point. Never blocks Claude Code: always exits 0 and prints nothing.
func runClaudeStop(_ arguments: [String]) -> Never {
    signal(SIGALRM) { _ in _exit(0) }
    alarm(10)

    var events: Set<String> = ["Stop"]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        // Test-only: lets a differently named event (e.g. SubagentStop) exercise the same code path.
        if argument == "--allow-event", let name = iterator.next() { events.insert(name) }
    }

    let configURL = ConfigFileStore.defaultURL()
    let handler = ClaudeStopHandler(store: ConfigFileStore(url: configURL), clipboard: PasteboardWriter(), allowedEvents: events)
    let outcome = handler.handle(stdin: readStandardInput(limit: ClaudeStopHandler.maxPayloadBytes))
    HookEventRecord.write(outcome, besides: configURL)
    exit(0)
}

func runManagement(_ command: String, _ arguments: [String]) -> Never {
    var settingsOverride: String?
    var apply = false
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--settings": settingsOverride = iterator.next()
        case "--apply": apply = true
        default: fail("Neznámý parametr: \(argument)")
        }
    }

    let configURL = ConfigFileStore.defaultURL()
    var environment = ProcessInfo.processInfo.environment
    if let settingsOverride { environment["PURECLIPBOARD_CLAUDE_SETTINGS_PATH"] = settingsOverride }
    let installer = ClaudeHookInstaller(paths: .standard(configURL: configURL, environment: environment))
    let selfURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])

    do {
        switch command {
        case "status-claude":
            let state = installer.state(bundledHelper: selfURL)
            printLine("settings:   \(installer.paths.settings.path)\(state.settingsExists ? "" : " (neexistuje)")")
            printLine("hook:       \(state.isRegistered ? "nainstalován (\(state.registeredCount))" : "nenainstalován")")
            printLine("helper:     \(state.helperInstalled ? installer.paths.helper.path : "není nainstalován")")
            if let matches = state.helperMatchesBundled { printLine("aktuální:   \(matches ? "ano" : "ne – spusťte install-claude --apply")") }
            printLine("jiné Stop hooky: \(state.otherStopHandlers)")
            if state.hooksDisabled { printLine("POZOR: v nastavení je disableAllHooks = true, hooky se nespouštějí.") }
            if let problem = state.settingsProblem { printLine("problém:    \(problem)") }
        case "install-claude", "uninstall-claude":
            let report = command == "install-claude"
                ? try installer.install(bundledHelper: selfURL, dryRun: !apply)
                : try installer.uninstall(dryRun: !apply)
            if report.steps.isEmpty { printLine("Není co měnit.") }
            for step in report.steps { printLine("• \(step)") }
            if !apply {
                if report.changed { printLine("Nic se nezměnilo. Pro provedení přidejte --apply.") }
            } else if report.changed {
                if let backup = report.backup { printLine("Záloha: \(backup.path)") }
                printLine("Hotovo.")
            }
        default:
            fail("Neznámý příkaz")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude-stop":
    runClaudeStop(Array(arguments.dropFirst()))
case "install-claude", "uninstall-claude", "status-claude":
    runManagement(arguments[0], Array(arguments.dropFirst()))
case "version":
    printLine(PureClipboardVersion.string)
default:
    printLine("""
    pureclipboard-hook \(PureClipboardVersion.string)
    Použití:
      claude-stop                       hook pro událost Stop (čte JSON ze stdin)
      status-claude                     stav integrace
      install-claude [--apply]          bez --apply pouze ukáže plán
      uninstall-claude [--apply]        bez --apply pouze ukáže plán
      volitelně: --settings CESTA       jiný soubor nastavení Claude Code
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
