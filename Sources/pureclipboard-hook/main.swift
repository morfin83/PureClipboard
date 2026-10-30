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

/// `pclip` entry point: copies the output of one explicitly wrapped command. Prints one line to stderr, never fails the command.
func runTerminalCopy(_ arguments: [String]) -> Never {
    signal(SIGALRM) { _ in _exit(0) }
    alarm(15)

    var exitCode: Int32?
    var session = "terminal"
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--exit": exitCode = iterator.next().flatMap { Int32($0) }
        case "--session": if let value = iterator.next() { session = value }
        default: break
        }
    }

    let configURL = ConfigFileStore.defaultURL()
    let handler = TerminalCopyHandler(
        store: ConfigFileStore(url: configURL),
        clipboard: SystemClipboard(),
        claims: ClipboardClaimStore(directory: configURL.deletingLastPathComponent())
    )
    let outcome = handler.handle(
        output: readStandardInput(limit: TerminalCopyHandler.maxInputBytes), exitCode: exitCode, session: session)
    HookEventRecord.write(outcome, besides: configURL, integration: .terminal)
    switch outcome.result {
    case .copied:
        FileHandle.standardError.write(Data("📋 Pure Clipboard: výstup zkopírován (\(outcome.characters) znaků).\n".utf8))
    case .skipped:
        let reason = outcome.reason == "empty-message" ? "no-output" : outcome.reason
        FileHandle.standardError.write(Data("Pure Clipboard: nekopíruji – \(HookReasonLabel.text(reason)).\n".utf8))
    }
    exit(0)
}

// MARK: Termux channel (S25 ↔ Mac). Always explicit commands run through the phone's existing SSH login.

func termuxContext() -> (store: ConfigFileStore, configURL: URL, handler: TermuxChannelHandler, support: URL) {
    let configURL = ConfigFileStore.defaultURL()
    let support = configURL.deletingLastPathComponent()
    let store = ConfigFileStore(url: configURL)
    return (store, configURL, TermuxChannelHandler(store: store, mailbox: TermuxMailbox(supportDirectory: support)), support)
}

func termuxExitCode(_ outcome: HookOutcome) -> Int32 {
    if outcome.result == .copied { return 0 }
    switch outcome.reason {
    case "nothing-to-fetch": return 3
    case "config-unavailable", "integration-off": return 4
    case "sensitive-content", "empty-message", "message-too-large", "payload-too-large", "invalid-device": return 5
    default: return 1
    }
}

func termuxReport(_ outcome: HookOutcome, success: String) {
    let message: String
    switch outcome.result {
    case .copied: message = success.replacingOccurrences(of: "{n}", with: String(outcome.characters))
    case .skipped:
        message = outcome.reason == "integration-off"
            ? "Pure Clipboard: Termux je v aplikaci vypnutý (zapněte přepínač Termux)."
            : "Pure Clipboard: nic se nestalo – \(HookReasonLabel.text(outcome.reason))."
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func termuxOption(_ name: String, in arguments: [String], default value: String) -> String {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return value }
    return arguments[index + 1]
}

func runTermux(_ command: String, _ arguments: [String]) -> Never {
    signal(SIGALRM) { _ in _exit(1) }
    alarm(20)
    let context = termuxContext()
    var outcome: HookOutcome
    switch command {
    case "termux-receive":
        let device = termuxOption("--from", in: arguments, default: "s25")
        outcome = context.handler.receive(readStandardInput(limit: TermuxText.maxInputBytes), from: device)
        termuxReport(outcome, success: "Pure Clipboard: text přijat do přijaté pošty ({n} znaků). Do schránky Macu ho zkopírujete v aplikaci.")
    case "termux-send":
        let device = termuxOption("--to", in: arguments, default: "s25")
        outcome = context.handler.send(readStandardInput(limit: TermuxText.maxInputBytes), to: device)
        termuxReport(outcome, success: "Pure Clipboard: text ({n} znaků) čeká na vyzvednutí telefonem (pcr frommac).")
    default: // termux-fetch
        let device = termuxOption("--for", in: arguments, default: "s25")
        let result = context.handler.fetch(for: device)
        outcome = result.outcome
        if let text = result.text { FileHandle.standardOutput.write(Data(text.utf8)) }
        termuxReport(outcome, success: "Pure Clipboard: doručeno ({n} znaků).")
    }
    HookEventRecord.write(outcome, besides: context.configURL, integration: .termux)
    exit(termuxExitCode(outcome))
}

/// Prints the Termux script. Needs no switch and no config: it only renders text.
func runTermuxScript(_ arguments: [String]) -> Never {
    let context = termuxContext()
    let helper = TermuxChannelInstaller(supportDirectory: context.support).helper
    let host = termuxOption("--host", in: arguments, default: "")
    let user = termuxOption("--user", in: arguments, default: NSUserName())
    printLine(TermuxScript.render(helper: helper, user: user, host: host.isEmpty ? nil : host).trimmingCharacters(in: .newlines))
    exit(0)
}

func runTermuxManagement(action: String, _ arguments: [String]) -> Never {
    var apply = false
    for argument in arguments {
        if argument == "--apply" { apply = true } else { fail("Neznámý parametr: \(argument)") }
    }
    let configURL = ConfigFileStore.defaultURL()
    let environment = ProcessInfo.processInfo.environment
    let installer = TermuxChannelInstaller(supportDirectory: configURL.deletingLastPathComponent())
    let selfURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    do {
        switch action {
        case "status":
            let state = installer.state()
            printLine("integrace:  Termux (S25 ↔ Mac)")
            printLine("pomocný program: \(state.helperInstalled ? installer.helper.path : "není nainstalován")")
            printLine("pošta:      \(state.mailboxReady ? "připravena (přijato: \(state.inboxCount), k odeslání: \(state.outboxCount))" : "není připravena")")
            printLine("skript pro Termux: pureclipboard-hook termux-script --host ADRESA_MACU")
        default:
            let report = action == "install"
                ? try installer.install(bundledHelper: selfURL, dryRun: !apply)
                : try installer.uninstall(
                    dryRun: !apply,
                    removeHelper: !otherIntegrationRegistered(excluding: "termux", environment: environment, configURL: configURL))
            if report.steps.isEmpty { printLine("Není co měnit.") }
            for step in report.steps { printLine("• \(step)") }
            if !apply {
                if report.changed { printLine("Nic se nezměnilo. Pro provedení přidejte --apply.") }
            } else if report.changed {
                printLine("Hotovo.")
                if action == "install" {
                    printLine("Na telefonu v Termuxu: ssh UŽIVATEL@ADRESA_MACU '\(installer.helper.path)' termux-script --host ADRESA_MACU > ~/pcr && chmod +x ~/pcr")
                }
            }
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}

/// True if any integration other than `excluded` still points at the shared helper copy.
func otherIntegrationRegistered(excluding excluded: String, environment: [String: String], configURL: URL) -> Bool {
    for target in HookTarget.allCases where target.rawValue != excluded {
        let installer = ClaudeHookInstaller(paths: .standard(target: target, configURL: configURL, environment: environment), target: target)
        if installer.state().isRegistered { return true }
    }
    if excluded != "terminal",
       ZshIntegrationInstaller(paths: .standard(configURL: configURL, environment: environment)).state().isInstalled { return true }
    if excluded != "termux",
       TermuxChannelInstaller(supportDirectory: configURL.deletingLastPathComponent()).state().isInstalled { return true }
    return false
}

func runTerminalManagement(action: String, _ arguments: [String]) -> Never {
    var override: String?
    var apply = false
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--settings", "--zshrc": override = iterator.next()
        case "--apply": apply = true
        default: fail("Neznámý parametr: \(argument)")
        }
    }
    let configURL = ConfigFileStore.defaultURL()
    var environment = ProcessInfo.processInfo.environment
    if let override { environment["PURECLIPBOARD_ZSHRC_PATH"] = override }
    let installer = ZshIntegrationInstaller(paths: .standard(configURL: configURL, environment: environment))
    let selfURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])

    do {
        switch action {
        case "status":
            let state = installer.state(bundledHelper: selfURL)
            printLine("integrace:  Apple Terminal (příkaz pclip)")
            printLine(".zshrc:     \(installer.paths.zshrc.path)\(state.zshrcExists ? "" : " (neexistuje)")")
            printLine("blok:       \(state.blockPresent ? "přidán" : "nepřidán")")
            printLine("skript:     \(state.snippetInstalled ? installer.paths.snippet.path : "není nainstalován")")
            if let current = state.snippetCurrent { printLine("aktuální:   \(current ? "ano" : "ne – spusťte install-terminal --apply")") }
            printLine("helper:     \(state.helperInstalled ? installer.paths.helper.path : "není nainstalován")")
            if let problem = state.problem { printLine("problém:    \(problem)") }
            for note in state.notes { printLine("poznámka:   \(note)") }
        case "install", "uninstall":
            let report = action == "install"
                ? try installer.install(bundledHelper: selfURL, dryRun: !apply)
                : try installer.uninstall(
                    dryRun: !apply,
                    removeHelper: !otherIntegrationRegistered(excluding: "terminal", environment: environment, configURL: configURL))
            if report.steps.isEmpty { printLine("Není co měnit.") }
            for step in report.steps { printLine("• \(step)") }
            if !apply {
                if report.changed { printLine("Nic se nezměnilo. Pro provedení přidejte --apply.") }
            } else if report.changed {
                if let backup = report.backup { printLine("Záloha: \(backup.path)") }
                printLine("Hotovo.")
                if action == "install" { printLine("Otevřete nové okno Terminálu (nebo spusťte: source ~/.zshrc) a zkuste: pclip echo test") }
            }
        default:
            fail("Neznámý příkaz")
        }
    } catch {
        fail(error.localizedDescription)
    }
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
                : try current.uninstall(
                    dryRun: !apply,
                    removeHelper: !otherIntegrationRegistered(excluding: target.rawValue, environment: environment, configURL: configURL))
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
/// Hands files to the running app, which sends them to the phone (Finder quick action, scripts). Reads only paths.
func runTransferEnqueue(_ arguments: [String]) -> Never {
    let paths = arguments.filter { !$0.hasPrefix("--") }
    guard !paths.isEmpty else { fail("Použití: transfer-enqueue SOUBOR [SOUBOR…]") }
    let files = paths.filter {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
    guard !files.isEmpty else { fail("Pure Clipboard: žádný z vybraných zdrojů není soubor (složky se neodesílají).") }
    let store = TransferStore(supportDirectory: ConfigFileStore.defaultURL().deletingLastPathComponent())
    do {
        let count = try store.enqueueRequest(paths: files)
        printLine("Pure Clipboard: \(count) souborů předáno aplikaci k odeslání do telefonu.")
        exit(0)
    } catch {
        fail("Pure Clipboard: požadavek se nepodařilo uložit (\(error.localizedDescription)).")
    }
}

let command = arguments.first ?? ""
let rest = Array(arguments.dropFirst())

switch command {
case "claude-stop":
    runStop(.claude, rest)
case "codex-stop":
    runStop(.codex, rest)
case "terminal-copy":
    runTerminalCopy(rest)
case "termux-receive", "termux-send", "termux-fetch":
    runTermux(command, rest)
case "termux-script":
    runTermuxScript(rest)
case "transfer-enqueue":
    runTransferEnqueue(rest)
case "version":
    printLine(PureClipboardVersion.string)
default:
    let parts = command.split(separator: "-", maxSplits: 1).map(String.init)
    if parts.count == 2, ["install", "uninstall", "status"].contains(parts[0]) {
        if parts[1] == "terminal" { runTerminalManagement(action: parts[0], rest) }
        if parts[1] == "termux" { runTermuxManagement(action: parts[0], rest) }
        if let target = HookTarget(rawValue: parts[1]) { runManagement(action: parts[0], target: target, rest) }
    }
    printLine("""
    pureclipboard-hook \(PureClipboardVersion.string)
    Použití:
      claude-stop | codex-stop          hook pro událost Stop (čte JSON ze stdin)
      terminal-copy [--exit N]          zkopíruje výstup příkazu ze stdin (volá funkce pclip)
      termux-receive [--from s25]       text ze stdin (z telefonu) do přijaté pošty
      termux-fetch [--for s25]          vydá jednou text odeslaný z Macu (stdout)
      termux-send [--to s25]            text ze stdin zařadí k odeslání do telefonu
      termux-script [--host H]          vypíše skript pcr pro Termux
      transfer-enqueue SOUBOR…          předá soubory aplikaci k odeslání do telefonu
      status-/install-/uninstall-termux kanál S25 ↔ Mac
      status-<claude|codex|terminal>    stav integrace
      install-<claude|codex|terminal>   bez --apply pouze ukáže plán
      uninstall-<claude|codex|terminal> bez --apply pouze ukáže plán
      volitelně: --settings CESTA       jiný soubor (settings.json / hooks.json / .zshrc)
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
