import Foundation
import Testing
@testable import PureClipboardCore

private let sampleJSON = """
{
  "schemaVersion": 1,
  "global": { "autoCopy": false, "historyLimit": 20, "protectSensitiveData": true },
  "integrations": {
    "terminal": { "enabled": false, "mode": "diagnostics" },
    "claudeCode": { "enabled": false, "mode": "finalResponse" },
    "codex": { "enabled": false, "mode": "finalResponse" },
    "pureRemote": { "enabled": false, "mode": "actionResults" },
    "termux": { "enabled": false, "mode": "localClipboard" }
  }
}
"""

private final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PureClipboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String, mode: Int = 0o600) throws -> ConfigFileStore {
        let file = url.appendingPathComponent("config.json")
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return ConfigFileStore(url: file)
    }
}

private func mode(of url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

private func object(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Suite struct ConfigStoreTests {
    @Test func loadsExistingConfig() throws {
        let dir = try TempDir()
        let loaded = try dir.write(sampleJSON).load()
        #expect(loaded.document.config == .defaults)
        #expect(loaded.permissions == 0o600)
    }

    @Test func toggleSaveAndReload() throws {
        let dir = try TempDir()
        let store = try dir.write(sampleJSON)
        var loaded = try store.load()
        loaded.document.config.global.autoCopy = true
        loaded.document.config.integrations[.claudeCode].enabled = true
        loaded.document.config.global.historyLimit = 50
        try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)

        let reloaded = try store.load().document.config
        #expect(reloaded.global.autoCopy)
        #expect(reloaded.integrations.claudeCode.enabled)
        #expect(!reloaded.integrations.codex.enabled)
        #expect(reloaded.global.historyLimit == 50)
    }

    @Test func preservesUnknownKeysAtEveryLevel() throws {
        let json = """
        {
          "schemaVersion": 1,
          "futureTopLevel": { "nested": [1, 2.5, "x", null, true] },
          "global": { "autoCopy": false, "historyLimit": 20, "protectSensitiveData": true, "futureGlobal": "keep" },
          "integrations": {
            "terminal": { "enabled": false, "mode": "diagnostics", "futureOption": 42 },
            "claudeCode": { "enabled": false, "mode": "finalResponse" },
            "codex": { "enabled": false, "mode": "finalResponse" },
            "pureRemote": { "enabled": false, "mode": "actionResults" },
            "termux": { "enabled": false, "mode": "localClipboard" },
            "futureIntegration": { "enabled": true, "mode": "something" }
          }
        }
        """
        let dir = try TempDir()
        let store = try dir.write(json)
        var loaded = try store.load()
        loaded.document.config.integrations[.terminal].enabled = true
        try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)

        let saved = try object(Data(contentsOf: store.url))
        let future = saved["futureTopLevel"] as! [String: Any]
        let nested = future["nested"] as! [Any]
        #expect(nested.count == 5)
        #expect((nested[1] as! NSNumber).doubleValue == 2.5)
        #expect((saved["global"] as! [String: Any])["futureGlobal"] as? String == "keep")
        let integrations = saved["integrations"] as! [String: Any]
        let terminal = integrations["terminal"] as! [String: Any]
        #expect(terminal["futureOption"] as? Int == 42)
        #expect(terminal["enabled"] as? Bool == true)
        #expect((integrations["futureIntegration"] as! [String: Any])["mode"] as? String == "something")
    }

    @Test func savesWithMode0600EvenIfFileWasLooser() throws {
        let dir = try TempDir()
        let store = try dir.write(sampleJSON, mode: 0o644)
        #expect(try store.load().permissions == 0o644)
        var loaded = try store.load()
        loaded.document.config.global.autoCopy = true
        try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        #expect(try mode(of: store.url) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func invalidJSONFailsAndFileIsUntouched() throws {
        let dir = try TempDir()
        let store = try dir.write("{ not json")
        #expect { try store.load() } throws: { error in
            if case ConfigError.invalidJSON = error { true } else { false }
        }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{ not json")
    }

    @Test func missingKeyIsStructureError() throws {
        let dir = try TempDir()
        let store = try dir.write(#"{"schemaVersion":1,"global":{"autoCopy":true},"integrations":{}}"#)
        #expect { try store.load() } throws: { error in
            if case ConfigError.invalidStructure = error { true } else { false }
        }
    }

    @Test func invalidValuesAreRejectedOnLoadAndSave() throws {
        let dir = try TempDir()
        let bad = sampleJSON.replacingOccurrences(of: "\"historyLimit\": 20", with: "\"historyLimit\": 0")
        #expect { try dir.write(bad).load() } throws: { error in
            if case ConfigError.invalidValues = error { true } else { false }
        }

        let store = try dir.write(sampleJSON)
        let before = try Data(contentsOf: store.url)
        var loaded = try store.load()
        loaded.document.config.integrations[.codex].mode = "bad mode; rm -rf"
        #expect(throws: ConfigError.self) { try store.save(loaded.document, expectedFingerprint: loaded.fingerprint) }
        #expect(try Data(contentsOf: store.url) == before)
    }

    @Test func refusesToOverwriteExternalChanges() throws {
        let dir = try TempDir()
        let store = try dir.write(sampleJSON)
        var loaded = try store.load()
        let external = sampleJSON.replacingOccurrences(of: "\"historyLimit\": 20", with: "\"historyLimit\": 30")
        try Data(external.utf8).write(to: store.url)
        loaded.document.config.global.autoCopy = true
        #expect(throws: ConfigError.modifiedExternally) {
            try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        }
        #expect(try store.load().document.config.global.historyLimit == 30)
    }

    @Test func refusesToReplaceSymlink() throws {
        let dir = try TempDir()
        let target = try dir.write(sampleJSON)
        let link = dir.url.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.url)
        let store = ConfigFileStore(url: link)
        let loaded = try store.load()
        #expect(throws: ConfigError.symlinkRefused) {
            try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        }
    }

    @Test func createsDefaultOnlyWhenMissing() throws {
        let dir = try TempDir()
        let store = ConfigFileStore(url: dir.url.appendingPathComponent("sub/config.json"))
        #expect(throws: ConfigError.fileNotFound(store.url.path)) { try store.load() }
        try store.save(ConfigDocument(config: .defaults), expectedFingerprint: nil)
        #expect(try store.load().document.config == .defaults)
        #expect(try mode(of: store.url) == 0o600)
        #expect(throws: ConfigError.modifiedExternally) {
            try store.save(ConfigDocument(config: .defaults), expectedFingerprint: nil)
        }
    }

    /// Round-trips a *copy* of the user's real config; the original is only read.
    @Test func realConfigCopyRoundTrips() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PureClipboard/config.json")
        guard let original = try? Data(contentsOf: real) else { return }
        let dir = try TempDir()
        let store = try dir.write(String(decoding: original, as: UTF8.self))
        var loaded = try store.load()
        loaded.document.config.integrations[.termux].enabled.toggle()
        try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)
        loaded = try store.load()
        loaded.document.config.integrations[.termux].enabled.toggle()
        try store.save(loaded.document, expectedFingerprint: loaded.fingerprint)

        let roundTripped = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.url))
        #expect(roundTripped == (try JSONDecoder().decode(JSONValue.self, from: original)))
        #expect(try Data(contentsOf: real) == original)
    }

    @Test func environmentOverridesConfigPath() {
        let url = ConfigFileStore.defaultURL(environment: ["PURECLIPBOARD_CONFIG_PATH": "/tmp/x/config.json"])
        #expect(url.path == "/tmp/x/config.json")
    }
}
