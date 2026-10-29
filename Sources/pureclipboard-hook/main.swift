import Darwin
import Foundation
import PureClipboardCore

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

/// Hook entry point for Claude Code and Codex `Stop`. Never blocks the agent: always exits 0 and prints nothing.
func runStop(_ target: HookTarget, _ arguments: [String]) -> Never {
    signal(SIGALRM) { _ in _exit(0) }
    alarm(10)

    var events: Set<String> = ["Stop"]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        // Test-only: lets a differently named event (e.g. SubagentStop) exercise the same code path.
        if argument == "--allow-event", let name = iterator.next() { events.insert(name) }
    }

    let configURL = ConfigFileStore.defaultURL()
    let handler = StopHookHandler(
        store: ConfigFileStore(url: configURL),
        clipboard: SystemClipboard(),
        integration: target.integration,
        allowedEvents: events,
        claims: ClipboardClaimStore(directory: configURL.deletingLastPathComponent())
    )
    let outcome = handler.handle(stdin: readStandardInput(limit: StopHookHandler.maxPayloadBytes))
    HookEventRecord.write(outcome, besides: configURL, integration: target.integration)
    exit(0)
}

func runManagement(action: String, target: HookTarget, _ arguments: [String]) -> Never {
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
    if let settingsOverride {
        environment[target == .claude ? "PURECLIPBOARD_CLAUDE_SETTINGS_PATH" : "PURECLIPBOARD_CODEX_HOOKS_PATH"] = settingsOverride
    }
    func installer(for target: HookTarget) -> ClaudeHookInstaller {
        ClaudeHookInstaller(paths: .standard(target: target, configURL: configURL, environment: environment), target: target)
    }
    let current = installer(for: target)
    let sibling = installer(for: target == .claude ? .codex : .claude)
    let selfURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])

    do {
        switch action {
        case "status":
            let state = current.state(bundledHelper: selfURL)
            printLine("integrace:  \(target.displayName)")
            printLine("soubor:     \(current.paths.settings.path)\(state.settingsExists ? "" : " (neexistuje)")")
            printLine("hook:       \(state.isRegistered ? "nainstalován (\(state.registeredCount))" : "nenainstalován")")
            printLine("helper:     \(state.helperInstalled ? current.paths.helper.path : "není nainstalován")")
            if let matches = state.helperMatchesBundled { printLine("aktuální:   \(matches ? "ano" : "ne – spusťte install-\(target.commandSuffix) --apply")") }
            printLine("jiné Stop hooky: \(state.otherStopHandlers)")
            if state.hooksDisabled { printLine("POZOR: v nastavení je disableAllHooks = true, hooky se nespouštějí.") }
            if let problem = state.settingsProblem { printLine("problém:    \(problem)") }
            for note in state.notes { printLine("poznámka:   \(note)") }
            if target == .codex && state.isRegistered {
                printLine("Codex spustí nový hook až po schválení: v Codexu zadejte /hooks a hook potvrďte.")
            }
        case "install", "uninstall":
            // The helper copy is shared; only the last remaining integration may delete it.
            let report = action == "install"
                ? try current.install(bundledHelper: selfURL, dryRun: !apply)
                : try current.uninstall(dryRun: !apply, removeHelper: !sibling.state().isRegistered)
            if report.steps.isEmpty { printLine("Není co měnit.") }
            for step in report.steps { printLine("• \(step)") }
            if !apply {
                if report.changed { printLine("Nic se nezměnilo. Pro provedení přidejte --apply.") }
            } else if report.changed {
                if let backup = report.backup { printLine("Záloha: \(backup.path)") }
                printLine("Hotovo.")
                if target == .codex && action == "install" {
                    printLine("Dále: spusťte Codex, zadejte /hooks a nový hook schvalte, jinak se nespustí.")
                }
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
let command = arguments.first ?? ""
let rest = Array(arguments.dropFirst())

switch command {
case "claude-stop":
    runStop(.claude, rest)
case "codex-stop":
    runStop(.codex, rest)
case "version":
    printLine(PureClipboardVersion.string)
default:
    let parts = command.split(separator: "-", maxSplits: 1).map(String.init)
    if parts.count == 2, ["install", "uninstall", "status"].contains(parts[0]),
       let target = HookTarget(rawValue: parts[1]) {
        runManagement(action: parts[0], target: target, rest)
    }
    printLine("""
    pureclipboard-hook \(PureClipboardVersion.string)
    Použití:
      claude-stop | codex-stop          hook pro událost Stop (čte JSON ze stdin)
      status-claude | status-codex      stav integrace
      install-claude | install-codex    bez --apply pouze ukáže plán
      uninstall-claude | uninstall-codex  bez --apply pouze ukáže plán
      volitelně: --settings CESTA       jiný soubor (settings.json / hooks.json)
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
