import Foundation
import Testing
@testable import PureClipboardCore

private final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    var writes: [String] = []
    func write(_ text: String) -> Bool { writes.append(text); return true }
}

private final class Env: @unchecked Sendable {
    let dir: URL
    let store: ConfigFileStore
    let mailbox: TermuxMailbox

    init(autoCopy: Bool = false, termux: Bool = true, protect: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCTermux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        var config = PureClipboardConfig.defaults
        config.global.autoCopy = autoCopy
        config.global.protectSensitiveData = protect
        config.integrations.termux.enabled = termux
        try store.save(ConfigDocument(config: config), expectedFingerprint: nil)
        mailbox = TermuxMailbox(supportDirectory: dir)
        for box in TermuxBox.allCases {
            try FileManager.default.createDirectory(at: mailbox.directory(box), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func handler(now: Date = Date()) -> TermuxChannelHandler { TermuxChannelHandler(store: store, mailbox: mailbox, now: { now }) }
    func setProtection(_ value: Bool) throws {
        var loaded = try store.load()
        loaded.document.config.global.protectSensitiveData = value
        try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
    }
    func mode(_ url: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
}

private func data(_ s: String) -> Data { Data(s.utf8) }
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct TermuxTextTests {
    @Test func normalisesLineEndingsAndDropsControlCharacters() {
        #expect(TermuxText.clean(data("\n\nahoj\r\nsvěte\r\u{07}\u{00}\tkonec  \n\n")) == "ahoj\nsvěte\n\tkonec")
    }

    @Test func invalidUTF8DoesNotCrash() {
        #expect(!TermuxText.clean(Data([0x61, 0xFF, 0x62])).isEmpty)
    }

    @Test(arguments: ["s25", "mac", "android-tv", "a", "tv2"])
    func acceptsPlainDeviceNames(name: String) { #expect(TermuxText.validDevice(name)) }

    @Test(arguments: ["", "S25", "-s25", "s 25", "s25;rm", "../etc", "s25\n", "příliš", String(repeating: "a", count: 33)])
    func rejectsOtherDeviceNames(name: String) { #expect(!TermuxText.validDevice(name)) }
}

@Suite struct TermuxMailboxTests {
    @Test func listsNewestFirstAndRoundTripsText() throws {
        let e = try Env()
        e.mailbox.add(TermuxItem(createdAt: t0, device: "s25", text: "první"), to: .inbox, now: t0)
        e.mailbox.add(TermuxItem(createdAt: t0.addingTimeInterval(5), device: "s25", text: "druhý ✓"), to: .inbox, now: t0.addingTimeInterval(5))
        #expect(e.mailbox.list(.inbox, now: t0.addingTimeInterval(6)).map(\.text) == ["druhý ✓", "první"])
        #expect(e.mailbox.list(.outbox, now: t0).isEmpty)
    }

    @Test func itemsAreExactlyOnceDeliveredAndFilesArePrivate() throws {
        let e = try Env()
        let item = TermuxItem(createdAt: t0, device: "s25", text: "jednou")
        e.mailbox.add(item, to: .outbox, now: t0)
        let file = e.mailbox.directory(.outbox).appendingPathComponent("\(item.id).json")
        #expect(try e.mode(file) == 0o600)
        #expect(try e.mode(e.mailbox.directory(.outbox)) == 0o700)
        #expect(e.mailbox.takeNewest(from: .outbox, now: t0)?.text == "jednou")
        #expect(e.mailbox.takeNewest(from: .outbox, now: t0) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func expiredItemsDisappear() throws {
        let e = try Env()
        e.mailbox.add(TermuxItem(createdAt: t0, device: "s25", text: "stará"), to: .inbox, now: t0)
        #expect(e.mailbox.list(.inbox, now: t0.addingTimeInterval(TermuxMailbox.maxAge - 1)).count == 1)
        #expect(e.mailbox.list(.inbox, now: t0.addingTimeInterval(TermuxMailbox.maxAge + 1)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.mailbox.directory(.inbox).path).isEmpty)
    }

    @Test func boxKeepsOnlyTheNewestItems() throws {
        let e = try Env()
        for i in 0..<(TermuxMailbox.maxItems + 5) {
            let time = t0.addingTimeInterval(Double(i))
            e.mailbox.add(TermuxItem(createdAt: time, device: "s25", text: "položka \(i)"), to: .inbox, now: time)
        }
        let items = e.mailbox.list(.inbox, now: t0.addingTimeInterval(100))
        #expect(items.count == TermuxMailbox.maxItems)
        #expect(items.first?.text == "položka \(TermuxMailbox.maxItems + 4)")
        #expect(!items.contains { $0.text == "položka 0" })
    }

    @Test func corruptFilesAreSweptAndIdsCannotEscapeTheFolder() throws {
        let e = try Env()
        try Data("{ nonsense".utf8).write(to: e.mailbox.directory(.inbox).appendingPathComponent("bad.json"))
        #expect(e.mailbox.list(.inbox, now: t0).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.mailbox.directory(.inbox).path).isEmpty)

        let victim = e.dir.appendingPathComponent("victim.json")
        try Data("keep".utf8).write(to: victim)
        e.mailbox.remove(id: "../../victim", from: .inbox)
        e.mailbox.remove(id: "../victim", from: .inbox)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func removeAllEmptiesOneBoxOnly() throws {
        let e = try Env()
        e.mailbox.add(TermuxItem(createdAt: t0, device: "s25", text: "a"), to: .inbox, now: t0)
        e.mailbox.add(TermuxItem(createdAt: t0, device: "s25", text: "b"), to: .outbox, now: t0)
        e.mailbox.removeAll(.inbox)
        #expect(e.mailbox.list(.inbox, now: t0).isEmpty && e.mailbox.list(.outbox, now: t0).count == 1)
    }

    @Test func concurrentWritersLoseNothing() throws {
        let e = try Env()
        let group = DispatchGroup()
        for i in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                e.mailbox.add(TermuxItem(createdAt: t0.addingTimeInterval(Double(i)), device: "s25", text: "souběh \(i)"), to: .inbox, now: t0.addingTimeInterval(20))
                group.leave()
            }
        }
        group.wait()
        #expect(e.mailbox.list(.inbox, now: t0.addingTimeInterval(21)).count == 12)
    }
}

@Suite struct TermuxHandlerTests {
    @Test func receiveStoresInInboxAndIgnoresAutoCopy() throws {
        let e = try Env(autoCopy: false)
        let outcome = e.handler().receive(data("text z telefonu\r\n"), from: "s25")
        #expect(outcome.result == .copied && outcome.reason == "received" && outcome.characters == 15)
        #expect(e.mailbox.list(.inbox, now: Date()).map(\.text) == ["text z telefonu"])
        #expect(e.mailbox.list(.outbox, now: Date()).isEmpty)
    }

    @Test func switchOffAndBrokenConfigStoreNothing() throws {
        let off = try Env(termux: false)
        let a = off.handler().receive(data("x"), from: "s25")
        #expect(a.reason == "integration-off" && !a.shouldRecord)
        #expect(off.handler().send(data("x"), to: "s25").reason == "integration-off")
        #expect(off.handler().fetch(for: "s25").outcome.reason == "integration-off")
        #expect(off.mailbox.list(.inbox, now: Date()).isEmpty && off.mailbox.list(.outbox, now: Date()).isEmpty)

        let broken = try Env()
        try Data("{ broken".utf8).write(to: broken.store.url)
        #expect(broken.handler().receive(data("x"), from: "s25").reason == "config-unavailable")
        #expect(broken.mailbox.list(.inbox, now: Date()).isEmpty)
        #expect(try String(contentsOf: broken.store.url, encoding: .utf8) == "{ broken")
    }

    @Test func otherIntegrationsDoNotEnableTermux() throws {
        let e = try Env(termux: false)
        var loaded = try e.store.load()
        loaded.document.config.integrations.claudeCode.enabled = true
        loaded.document.config.integrations.terminal.enabled = true
        loaded.document.config.integrations.codex.enabled = true
        try e.store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        #expect(e.handler().receive(data("x"), from: "s25").reason == "integration-off")
    }

    @Test func sensitiveTextIsRefusedInBothDirections() throws {
        let e = try Env()
        let secret = "ghp_" + String(repeating: "Ab9", count: 12)
        let a = e.handler().receive(data("klíč: \(secret)"), from: "s25")
        #expect(a.reason == "sensitive-content" && a.findings.contains("github-token"))
        #expect(e.handler().send(data("klíč: \(secret)"), to: "s25").reason == "sensitive-content")
        #expect(e.mailbox.list(.inbox, now: Date()).isEmpty && e.mailbox.list(.outbox, now: Date()).isEmpty)
        HookEventRecord.write(a, besides: e.store.url, integration: .termux)
        let log = try String(contentsOf: HookEventRecord.fileURL(besides: e.store.url, integration: .termux), encoding: .utf8)
        #expect(!log.contains(secret))
    }

    @Test func protectionOffAcceptsAnything() throws {
        let e = try Env(protect: false)
        #expect(e.handler().receive(data("password = " + "Tr0ub4dor&3x"), from: "s25").result == .copied)
    }

    @Test func invalidInputIsRejected() throws {
        let e = try Env()
        #expect(e.handler().receive(data("x"), from: "../s25").reason == "invalid-device")
        #expect(e.handler().receive(data("  \n\t "), from: "s25").reason == "empty-message")
        #expect(e.handler().receive(Data(count: TermuxText.maxInputBytes + 1), from: "s25").reason == "payload-too-large")
        #expect(e.handler().receive(data(String(repeating: "a", count: TermuxText.maxCharacters + 1)), from: "s25").reason == "message-too-large")
        #expect(e.mailbox.list(.inbox, now: Date()).isEmpty)
    }

    @Test func sendThenFetchDeliversOnceAndNeverFromTheInbox() throws {
        let e = try Env()
        _ = e.handler().receive(data("tohle patří Macu"), from: "s25")
        #expect(e.handler().send(data("pro telefon"), to: "s25").reason == "queued")
        let first = e.handler().fetch(for: "s25")
        #expect(first.outcome.reason == "delivered" && first.text == "pro telefon" && first.outcome.characters == 11)
        let second = e.handler().fetch(for: "s25")
        #expect(second.outcome.reason == "nothing-to-fetch" && second.text == nil)
        #expect(e.mailbox.list(.inbox, now: Date()).count == 1)
    }

    @Test func fetchRescansWhenProtectionWasSwitchedOnLater() throws {
        let e = try Env(protect: false)
        let text = "TOKEN=" + "abcdef123456"
        #expect(e.handler().send(data(text), to: "s25").result == .copied)
        try e.setProtection(true)
        let result = e.handler().fetch(for: "s25")
        #expect(result.outcome.reason == "sensitive-content" && result.text == nil)
        #expect(e.mailbox.list(.outbox, now: Date()).isEmpty, "a refused item must not wait around")
    }

    @Test func staleOutboxItemIsNotDelivered() throws {
        let e = try Env()
        _ = e.handler(now: t0).send(data("stará"), to: "s25")
        #expect(e.handler(now: t0.addingTimeInterval(TermuxMailbox.maxAge + 5)).fetch(for: "s25").outcome.reason == "nothing-to-fetch")
    }

    @Test func copyToClipboardIsExplicitAndClaimsTheClipboard() throws {
        let e = try Env()
        let clip = FakeClipboard()
        let item = TermuxItem(createdAt: t0, device: "s25", text: "z telefonu")
        let claims = ClipboardClaimStore(directory: e.dir)
        let outcome = e.handler(now: t0).copyToClipboard(item, clipboard: clip, claims: claims)
        #expect(outcome.result == .copied && clip.writes == ["z telefonu"])
        #expect(claims.lastClaim()?.source == "termux")

        let off = try Env(termux: false)
        let blocked = off.handler().copyToClipboard(item, clipboard: clip, claims: nil)
        #expect(blocked.reason == "integration-off" && clip.writes.count == 1)
    }

    @Test func receivingNeverTouchesTheClipboardOrClaims() throws {
        let e = try Env()
        _ = e.handler().receive(data("tiše do pošty"), from: "s25")
        #expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("clipboard-claim.json").path))
    }
}

@Suite struct TermuxInstallerTests {
    private func makeSupport() throws -> (support: URL, helper: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCTermuxInst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let helper = dir.appendingPathComponent("helper-src")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return (dir.appendingPathComponent("support"), helper)
    }

    @Test func installCreatesPrivateMailboxAndHelperOnly() throws {
        let (support, source) = try makeSupport(); defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let installer = TermuxChannelInstaller(supportDirectory: support)
        #expect(!installer.state().isInstalled)
        let plan = try installer.install(bundledHelper: source, dryRun: true)
        #expect(plan.changed && plan.steps.contains { $0.contains("authorized_keys") })
        #expect(!FileManager.default.fileExists(atPath: support.path))

        try installer.install(bundledHelper: source)
        #expect(installer.state().isInstalled)
        let mode = try (FileManager.default.attributesOfItem(atPath: installer.mailbox.directory(.inbox).path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o700)
        #expect(FileManager.default.isExecutableFile(atPath: installer.helper.path))
        #expect(try !installer.install(bundledHelper: source).changed)
    }

    @Test func uninstallDeletesWaitingTextsAndRespectsSharedHelper() throws {
        let (support, source) = try makeSupport(); defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let installer = TermuxChannelInstaller(supportDirectory: support)
        try installer.install(bundledHelper: source)
        installer.mailbox.add(TermuxItem(createdAt: Date(), device: "s25", text: "čeká"), to: .inbox)
        #expect(installer.state().inboxCount == 1)
        try installer.uninstall(removeHelper: false)
        #expect(!FileManager.default.fileExists(atPath: installer.mailbox.root.path))
        #expect(FileManager.default.isExecutableFile(atPath: installer.helper.path))
        try installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: installer.helper.path))
    }

    @Test func installRefusesMissingHelper() throws {
        let (support, _) = try makeSupport(); defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let missing = support.appendingPathComponent("nope")
        #expect(throws: ClaudeHookError.helperMissing(missing.path)) {
            try TermuxChannelInstaller(supportDirectory: support).install(bundledHelper: missing)
        }
    }
}

// MARK: The Termux script, run with a fake `ssh` and fake termux-api

private struct ScriptLab {
    let dir: URL
    let bin: URL
    let script: URL
    let stubHelper: URL

    init(helperBehaviour: String, helperName: String = "helper with space's") throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PCPcr-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stubHelper = dir.appendingPathComponent(helperName)
        try ScriptLab.write(stubHelper, helperBehaviour)
        // Fake ssh: the last argument is the remote command line; run it locally with stdin/stdout passed through.
        try ScriptLab.write(bin.appendingPathComponent("ssh"), "#!/bin/sh\nfor last; do :; done\nprintf '%s\\n' \"$@\" > \"\(dir.path)/ssh-args\"\nexec /bin/sh -c \"$last\"\n")
        try ScriptLab.write(bin.appendingPathComponent("termux-clipboard-get"), "#!/bin/sh\ncat \"\(dir.path)/phone-clipboard\"\n")
        try ScriptLab.write(bin.appendingPathComponent("termux-clipboard-set"), "#!/bin/sh\ncat > \"\(dir.path)/phone-clipboard-written\"\n")
        let script = dir.appendingPathComponent("pcr")
        try ScriptLab.write(script, TermuxScript.render(helper: stubHelper, user: "pavel", host: "mac-test"))
        self.dir = dir
        self.bin = bin
        self.stubHelper = stubHelper
        self.script = script
    }

    private static func write(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func setPhoneClipboard(_ text: String) throws { try Data(text.utf8).write(to: dir.appendingPathComponent("phone-clipboard")) }
    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    func run(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin"
        env["HOME"] = dir.path
        env["XDG_CONFIG_HOME"] = dir.appendingPathComponent("cfg").path
        env["TMPDIR"] = dir.path
        for key in ["PCR_HOST", "PCR_USER", "PCR_DEVICE"] { env[key] = nil }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

@Suite struct TermuxScriptTests {
    @Test func renderedScriptIsValidPOSIXShellWithSafeQuoting() throws {
        let script = TermuxScript.render(helper: URL(fileURLWithPath: "/Users/o'brien/Library/Application Support/PureClipboard/bin/pureclipboard-hook"), user: "pavel", host: nil)
        #expect(script.hasPrefix("#!/data/data/com.termux/files/usr/bin/sh\n"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pcr-syntax-\(UUID().uuidString)")
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-n", file.path]
            let err = Pipe(); process.standardError = err
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(shell): \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
    }

    @Test func tomacSendsThePhoneClipboardToTheReceiveCommand() throws {
        let lab = try ScriptLab(helperBehaviour: "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/helper-args\"\ncat > \"$(dirname \"$0\")/helper-stdin\"\n")
        defer { try? FileManager.default.removeItem(at: lab.dir) }
        try lab.setPhoneClipboard("text z telefonu\nřádek dva")
        let result = try lab.run(["tomac"])
        #expect(result.status == 0, "\(result.err)")
        #expect(lab.read("helper-args")?.contains("termux-receive") == true && lab.read("helper-args")?.contains("--from") == true)
        #expect(lab.read("helper-stdin") == "text z telefonu\nřádek dva")
        let ssh = lab.read("ssh-args") ?? ""
        #expect(ssh.contains("pavel@mac-test") && ssh.contains("BatchMode=yes") && ssh.contains("ConnectTimeout=8"))
    }

    @Test func tomacRefusesEmptyPhoneClipboardWithoutCallingTheMac() throws {
        let lab = try ScriptLab(helperBehaviour: "#!/bin/sh\ntouch \"$(dirname \"$0\")/helper-called\"\n")
        defer { try? FileManager.default.removeItem(at: lab.dir) }
        try lab.setPhoneClipboard("")
        let result = try lab.run(["tomac"])
        #expect(result.status != 0 && result.err.contains("prázdná"))
        #expect(lab.read("helper-called") == nil)
    }

    @Test func frommacPutsDeliveredTextIntoThePhoneClipboard() throws {
        let lab = try ScriptLab(helperBehaviour: "#!/bin/sh\nprintf 'odpověď z Macu\\nškolní \"text\"'\n")
        defer { try? FileManager.default.removeItem(at: lab.dir) }
        let result = try lab.run(["frommac"])
        #expect(result.status == 0, "\(result.err)")
        #expect(lab.read("phone-clipboard-written") == "odpověď z Macu\nškolní \"text\"")
    }

    @Test func frommacNeverClobbersThePhoneClipboardWhenNothingIsWaiting() throws {
        let lab = try ScriptLab(helperBehaviour: "#!/bin/sh\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: lab.dir) }
        let result = try lab.run(["frommac"])
        #expect(result.status == 3)
        #expect(lab.read("phone-clipboard-written") == nil)

        let refused = try ScriptLab(helperBehaviour: "#!/bin/sh\nexit 5\n")
        defer { try? FileManager.default.removeItem(at: refused.dir) }
        #expect(try refused.run(["frommac"]).status == 5)
        #expect(refused.read("phone-clipboard-written") == nil)
    }

    @Test func missingHostIsExplainedAndSetupStoresIt() throws {
        let lab = try ScriptLab(helperBehaviour: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: lab.dir) }
        // Rendered with a host, so strip it to simulate a script fetched without --host.
        let plain = TermuxScript.render(helper: lab.stubHelper, user: "pavel", host: nil)
        try Data(plain.utf8).write(to: lab.script)
        try lab.setPhoneClipboard("x")
        let missing = try lab.run(["tomac"])
        #expect(missing.status != 0 && missing.err.contains("pcr setup"))
        #expect(try lab.run(["setup", "muj-mac", "jana"]).status == 0)
        let ok = try lab.run(["tomac"])
        #expect(ok.status == 0, "\(ok.err)")
        #expect((lab.read("ssh-args") ?? "").contains("jana@muj-mac"))
    }

    @Test func helpAndDoctorWork() throws {
        let lab = try ScriptLab(helperBehaviour: "#!/bin/sh\necho 0.6.0\n")
        defer { try? FileManager.default.removeItem(at: lab.dir) }
        #expect(try lab.run([]).out.contains("pcr tomac"))
        let doctor = try lab.run(["doctor"])
        #expect(doctor.status == 0 && doctor.out.contains("spojení s Macem: OK"))
    }
}
