import Darwin
import Foundation

// Text channel between the Mac and the user's phone (Termux on the S25).
//
// The phone always starts the connection (Termux → SSH → Mac) with the SSH key that already exists; this app opens no
// listener and changes no SSH setting. The Mac side offers four explicit commands, run through that SSH login:
//   termux-receive   phone → Mac: stores text in the *inbox* (it never touches the Mac clipboard by itself)
//   termux-fetch     Mac → phone: hands over the newest item of the *outbox* once and deletes it
//   termux-send      Mac side: puts text into the outbox (also used by the app's "send" button)
//   termux-script    prints the small Termux script `pcr` that calls the three commands above
// Every direction passes the same gates and the same sensitive-data scanner as the other integrations.

/// Cross-process exclusive lock on a file. Returns nil if the lock cannot be taken in time (callers then fail closed).
struct FileLock {
    static func withLock<T>(at url: URL, timeout: TimeInterval = 2, _ body: () -> T) -> T? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return nil }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}

public enum TermuxBox: String, Codable, CaseIterable, Sendable {
    /// Phone → Mac.
    case inbox
    /// Mac → phone.
    case outbox
}

public struct TermuxItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    /// Short lowercase label of the other device, e.g. "s25".
    public var device: String
    public var text: String

    public var characters: Int { text.count }

    public init(id: String = UUID().uuidString, createdAt: Date, device: String, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.device = device
        self.text = text
    }
}

/// Plain-text normalisation for text that arrives over the channel (untrusted).
public enum TermuxText {
    public static let maxInputBytes = 1024 * 1024
    public static let maxCharacters = 200_000

    public static func clean(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }
        var result = String(String.UnicodeScalarView(kept))
        while let first = result.first, first == "\n" { result.removeFirst() }
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }

    /// Device labels end up in file contents and logs: only short lowercase ASCII names are accepted.
    public static func validDevice(_ name: String) -> Bool {
        guard (1...32).contains(name.count), let first = name.unicodeScalars.first else { return false }
        let alnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard alnum.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { alnum.contains($0) || $0 == "-" }
    }
}

/// File based mailboxes in `<support>/termux/{inbox,outbox}` (directories 0700, items 0600).
/// Items expire after an hour and each box keeps at most 20 items, so nothing lingers.
public struct TermuxMailbox: Sendable {
    public static let maxItems = 20
    public static let maxAge: TimeInterval = 3600

    public let root: URL

    public init(supportDirectory: URL) {
        root = supportDirectory.appendingPathComponent("termux")
    }

    func directory(_ box: TermuxBox) -> URL { root.appendingPathComponent(box.rawValue) }
    var lockURL: URL { root.appendingPathComponent("mailbox.lock") }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads, purges expired and unreadable items. Must run under the lock when it is followed by a modification.
    private func load(_ box: TermuxBox, now: Date) -> [TermuxItem] {
        let dir = directory(box)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var items: [TermuxItem] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let item = try? decoder().decode(TermuxItem.self, from: data),
                  now.timeIntervalSince(item.createdAt) < Self.maxAge else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            items.append(item)
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    public func list(_ box: TermuxBox, now: Date = Date()) -> [TermuxItem] {
        FileLock.withLock(at: lockURL) { load(box, now: now) } ?? []
    }

    @discardableResult
    public func add(_ item: TermuxItem, to box: TermuxBox, now: Date = Date()) -> Bool {
        FileLock.withLock(at: lockURL) { () -> Bool in
            guard let data = try? encoder().encode(item) else { return false }
            do {
                try AtomicFile.write(data, to: directory(box).appendingPathComponent("\(item.id).json"), mode: 0o600)
            } catch {
                return false
            }
            for stale in load(box, now: now).dropFirst(Self.maxItems) {
                try? FileManager.default.removeItem(at: directory(box).appendingPathComponent("\(stale.id).json"))
            }
            return true
        } ?? false
    }

    /// Returns the newest item and deletes it (one-shot delivery).
    public func takeNewest(from box: TermuxBox, now: Date = Date()) -> TermuxItem? {
        FileLock.withLock(at: lockURL) { () -> TermuxItem? in
            guard let item = load(box, now: now).first else { return nil }
            try? FileManager.default.removeItem(at: directory(box).appendingPathComponent("\(item.id).json"))
            return item
        } ?? nil
    }

    public func remove(id: String, from box: TermuxBox) {
        guard id.range(of: #"^[0-9A-Fa-f-]{8,64}$"#, options: .regularExpression) != nil else { return }
        _ = FileLock.withLock(at: lockURL) {
            try? FileManager.default.removeItem(at: directory(box).appendingPathComponent("\(id).json"))
        }
    }

    public func removeAll(_ box: TermuxBox) {
        _ = FileLock.withLock(at: lockURL) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory(box), includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Decisions for the three text-moving commands. All of them fail closed and report only metadata.
public struct TermuxChannelHandler {
    public let store: ConfigFileStore
    public let mailbox: TermuxMailbox
    public let now: () -> Date

    public init(store: ConfigFileStore, mailbox: TermuxMailbox, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.mailbox = mailbox
        self.now = now
    }

    private func gates() -> (config: PureClipboardConfig?, refusal: HookOutcome?) {
        let config: PureClipboardConfig
        do {
            config = try store.load().document.config
        } catch {
            return (nil, .skipped("config-unavailable", record: false))
        }
        guard config.integrations.termux.enabled else { return (nil, .skipped("integration-off", record: false)) }
        return (config, nil)
    }

    /// Validates and stores text. Shared by receive (inbox) and send (outbox).
    private func accept(_ input: Data, device: String, box: TermuxBox, success: String) -> HookOutcome {
        let gate = gates()
        if let refusal = gate.refusal { return refusal }
        guard let config = gate.config else { return .skipped("config-unavailable", record: false) }

        guard TermuxText.validDevice(device) else { return .skipped("invalid-device") }
        guard input.count <= TermuxText.maxInputBytes else { return .skipped("payload-too-large") }
        let text = TermuxText.clean(input)
        guard !text.isEmpty else { return .skipped("empty-message") }
        guard text.count <= TermuxText.maxCharacters else { return .skipped("message-too-large", characters: text.count) }
        if config.global.protectSensitiveData {
            let findings = SensitiveDataScanner.scan(text)
            guard findings.isEmpty else { return .skipped("sensitive-content", characters: text.count, findings: findings) }
        }
        guard mailbox.add(TermuxItem(createdAt: now(), device: device, text: text), to: box, now: now()) else {
            return .skipped("mailbox-write-failed", characters: text.count)
        }
        return HookOutcome(result: .copied, reason: success, characters: text.count, findings: [], shouldRecord: true)
    }

    /// Phone → Mac: into the inbox. Never touches the clipboard.
    public func receive(_ input: Data, from device: String) -> HookOutcome {
        accept(input, device: device, box: .inbox, success: "received")
    }

    /// Mac → phone: into the outbox, waiting for the phone to fetch it.
    public func send(_ input: Data, to device: String) -> HookOutcome {
        accept(input, device: device, box: .outbox, success: "queued")
    }

    /// Hands the newest outbox item to the phone, once. The text is re-scanned because the protection setting may have changed.
    public func fetch(for device: String) -> (outcome: HookOutcome, text: String?) {
        let gate = gates()
        if let refusal = gate.refusal { return (refusal, nil) }
        guard let config = gate.config else { return (.skipped("config-unavailable", record: false), nil) }
        guard TermuxText.validDevice(device) else { return (.skipped("invalid-device"), nil) }
        guard let item = mailbox.takeNewest(from: .outbox, now: now()) else { return (.skipped("nothing-to-fetch"), nil) }
        if config.global.protectSensitiveData {
            let findings = SensitiveDataScanner.scan(item.text)
            guard findings.isEmpty else {
                return (.skipped("sensitive-content", characters: item.characters, findings: findings), nil)
            }
        }
        return (HookOutcome(result: .copied, reason: "delivered", characters: item.characters, findings: [], shouldRecord: true), item.text)
    }

    /// Mac clipboard write for an inbox item, on the user's explicit click. Claims the clipboard like `pclip` does.
    public func copyToClipboard(_ item: TermuxItem, clipboard: ClipboardWriting, claims: ClipboardClaimStore?) -> HookOutcome {
        let gate = gates()
        if let refusal = gate.refusal { return refusal }
        let candidate = ClipboardClaimStore.Claim(source: IntegrationID.termux.rawValue, session: "termux-inbox", time: now())
        let write = { () -> HookOutcome in
            guard clipboard.write(item.text) else { return .skipped("clipboard-write-failed", characters: item.characters) }
            return HookOutcome(result: .copied, reason: "ok", characters: item.characters, findings: [], shouldRecord: true)
        }
        guard let claims else { return write() }
        let outcome = claims.withLock { () -> HookOutcome in
            let result = write()
            if result.result == .copied { claims.record(candidate) }
            return result
        }
        return outcome ?? .skipped("lock-unavailable", characters: item.characters)
    }
}

// MARK: Termux script

public enum TermuxScript {
    public static let name = "pcr"

    /// POSIX shell script for Termux. `host` is baked in when known; otherwise the user runs `pcr setup HOST`.
    public static func render(helper: URL, user: String, host: String?) -> String {
        func single(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let remoteHelper = single(helper.path)
        return """
        #!/data/data/com.termux/files/usr/bin/sh
        # pcr – přenos textu mezi telefonem (Termux) a Macem s Pure Clipboard (\(PureClipboardVersion.string)).
        # Telefon se připojuje k Macu přes SSH (Tailscale) vaším stávajícím klíčem; na Macu se spustí jen pomocný program
        # Pure Clipboard. Nic na telefonu nenaslouchá a nic se nesleduje: přenos proběhne jen když spustíte příkaz.
        #
        #   pcr tomac       odešle schránku telefonu do přijaté pošty v aplikaci Pure Clipboard na Macu
        #   pcr frommac     vyzvedne text, který jste na Macu odeslali tlačítkem „Odeslat do S25“, a dá ho do schránky telefonu
        #   pcr doctor      zkontroluje požadavky a spojení
        #   pcr setup HOST [UŽIVATEL]   uloží adresu Macu (jméno v Tailscale nebo jeho IP)
        CONF="${XDG_CONFIG_HOME:-$HOME/.config}/pcr"
        DEFAULT_HOST=\(single(host ?? ""))
        DEFAULT_USER=\(single(user))
        HOST="${PCR_HOST:-$(cat "$CONF/host" 2>/dev/null)}"
        [ -n "$HOST" ] || HOST="$DEFAULT_HOST"
        USER_NAME="${PCR_USER:-$(cat "$CONF/user" 2>/dev/null)}"
        [ -n "$USER_NAME" ] || USER_NAME="$DEFAULT_USER"
        DEVICE="${PCR_DEVICE:-s25}"
        REMOTE_HELPER=\(single(remoteHelper))

        die() { echo "pcr: $*" >&2; exit 1; }
        need_host() { [ -n "$HOST" ] || die "chybí adresa Macu – spusťte: pcr setup JMENO-MACU"; }
        mac() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$USER_NAME@$HOST" "$@"; }

        case "${1:-help}" in
          tomac)
            need_host
            command -v termux-clipboard-get >/dev/null 2>&1 || die "chybí termux-clipboard-get (pkg install termux-api a aplikace Termux:API)"
            TMP="$(mktemp)" || die "nelze vytvořit dočasný soubor"
            trap 'rm -f "$TMP"' EXIT INT TERM
            termux-clipboard-get > "$TMP" || die "schránku telefonu se nepodařilo přečíst"
            [ -s "$TMP" ] || die "schránka telefonu je prázdná"
            mac "$REMOTE_HELPER termux-receive --from $DEVICE" < "$TMP"
            ;;
          frommac)
            need_host
            command -v termux-clipboard-set >/dev/null 2>&1 || die "chybí termux-clipboard-set (pkg install termux-api a aplikace Termux:API)"
            TMP="$(mktemp)" || die "nelze vytvořit dočasný soubor"
            trap 'rm -f "$TMP"' EXIT INT TERM
            mac "$REMOTE_HELPER termux-fetch --for $DEVICE" > "$TMP"
            RC=$?
            if [ "$RC" -eq 0 ] && [ -s "$TMP" ]; then
              termux-clipboard-set < "$TMP" && echo "pcr: text je ve schránce telefonu." >&2
            else
              echo "pcr: nic ke stažení (kód $RC); schránka telefonu zůstala beze změny." >&2
              exit "$RC"
            fi
            ;;
          doctor)
            echo "Mac: ${USER_NAME:-?}@${HOST:-?}"
            command -v ssh >/dev/null 2>&1 && echo "ssh: ano" || echo "ssh: CHYBÍ (pkg install openssh)"
            command -v termux-clipboard-get >/dev/null 2>&1 && echo "termux-api: ano" || echo "termux-api: CHYBÍ"
            need_host
            mac "$REMOTE_HELPER version" && echo "spojení s Macem: OK" || die "spojení nebo pomocný program na Macu nefunguje"
            ;;
          setup)
            [ -n "${2:-}" ] || die "použití: pcr setup HOST [UŽIVATEL]"
            mkdir -p "$CONF" && printf '%s\\n' "$2" > "$CONF/host" || die "nelze uložit nastavení"
            [ -z "${3:-}" ] || printf '%s\\n' "$3" > "$CONF/user"
            echo "pcr: uloženo ($CONF)."
            ;;
          *)
            sed -n '2,9p' "$0" | sed 's/^# \\{0,1\\}//'
            ;;
        esac
        """ + "\n"
    }
}

// MARK: Installer

public struct TermuxChannelState: Equatable, Sendable {
    public var helperInstalled = false
    public var mailboxReady = false
    public var inboxCount = 0
    public var outboxCount = 0

    public init() {}

    public var isInstalled: Bool { helperInstalled && mailboxReady }
}

/// "Installing" the channel means: a stable copy of the helper (for the phone to call) and the private mailbox folders.
/// No system, SSH or Tailscale configuration is touched.
public struct TermuxChannelInstaller: Sendable {
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public var helper: URL { supportDirectory.appendingPathComponent("bin/pureclipboard-hook") }
    public var mailbox: TermuxMailbox { TermuxMailbox(supportDirectory: supportDirectory) }

    public func state(now: Date = Date()) -> TermuxChannelState {
        var state = TermuxChannelState()
        state.helperInstalled = FileManager.default.isExecutableFile(atPath: helper.path)
        var isDirectory: ObjCBool = false
        state.mailboxReady = FileManager.default.fileExists(atPath: mailbox.directory(.inbox).path, isDirectory: &isDirectory) && isDirectory.boolValue
        if state.mailboxReady {
            state.inboxCount = mailbox.list(.inbox, now: now).count
            state.outboxCount = mailbox.list(.outbox, now: now).count
        }
        return state
    }

    @discardableResult
    public func install(bundledHelper: URL, dryRun: Bool = false) throws(ClaudeHookError) -> ClaudeHookReport {
        var report = ClaudeHookReport()
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else { throw .helperMissing(bundledHelper.path) }
        let helperBytes: Data
        do { helperBytes = try Data(contentsOf: bundledHelper) } catch { throw .io(error.localizedDescription) }
        let helperCurrent = (try? Data(contentsOf: helper)) == helperBytes
        let ready = state().mailboxReady

        if !helperCurrent { report.steps.append("Zkopíruje pomocný program do \(helper.path)") }
        if !ready { report.steps.append("Vytvoří soukromé složky pro přijatou a odesílanou poštu: \(mailbox.root.path) (0700)") }
        report.steps.append("Nemění SSH, authorized_keys, Tailscale ani žádný jiný soubor mimo složku Pure Clipboard")
        report.changed = !helperCurrent || !ready
        if dryRun || !report.changed { return report }

        do {
            if !helperCurrent { try AtomicFile.write(helperBytes, to: helper, mode: 0o755) }
            for box in TermuxBox.allCases {
                try FileManager.default.createDirectory(
                    at: mailbox.directory(box), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw .io(error.localizedDescription)
        }
        return report
    }

    /// Removes the mailbox folders (and any waiting texts). `removeHelper: false` keeps the helper shared with other integrations.
    @discardableResult
    public func uninstall(dryRun: Bool = false, removeHelper: Bool = true) throws(ClaudeHookError) -> ClaudeHookReport {
        var report = ClaudeHookReport()
        let mailboxPresent = FileManager.default.fileExists(atPath: mailbox.root.path)
        let helperPresent = removeHelper && FileManager.default.fileExists(atPath: helper.path)
        if mailboxPresent { report.steps.append("Smaže složku \(mailbox.root.path) včetně čekajících textů") }
        if helperPresent { report.steps.append("Smaže pomocný program \(helper.path)") }
        report.changed = mailboxPresent || helperPresent
        if dryRun || !report.changed { return report }
        do {
            if mailboxPresent { try FileManager.default.removeItem(at: mailbox.root) }
            if helperPresent { try FileManager.default.removeItem(at: helper) }
        } catch {
            throw .io(error.localizedDescription)
        }
        return report
    }
}
