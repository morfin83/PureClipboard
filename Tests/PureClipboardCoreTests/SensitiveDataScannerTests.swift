import Testing
@testable import PureClipboardCore

/// Fake credentials are assembled at runtime so no secret-shaped literal sits in the repository.
@Suite struct SensitiveDataScannerTests {
    private static func positives() -> [(sample: String, rule: String)] {
        var list: [(sample: String, rule: String)] = []
        let repeated: (String, Int) -> String = { String(repeating: $0, count: $1) }
        list.append(("-----BEGIN " + "RSA PRIVATE KEY" + "-----\nMIIE", "private-key"))
        list.append(("-----BEGIN " + "OPENSSH PRIVATE KEY" + "-----", "private-key"))
        list.append(("-----BEGIN PGP " + "PRIVATE KEY BLOCK" + "-----", "private-key"))
        list.append(("key id AKIA" + "ABCDEFGHIJKLMNOP", "aws-access-key"))
        list.append(("token ghp_" + repeated("a1B2c3", 6), "github-token"))
        list.append(("github_pat_" + repeated("Ab3_", 8), "github-token"))
        list.append(("xoxb-" + "1234567890-abcdefghij", "slack-token"))
        list.append(("ANTHROPIC sk-ant-" + "api03-" + repeated("x7Q", 10), "api-key-sk"))
        list.append(("AIza" + repeated("Ab3-", 9) + "Z", "google-api-key"))
        list.append(("sk_live_" + "51HabcdefGHIJKLmnop", "stripe-key"))
        list.append(("eyJhbGciOiJIUzI1" + ".eyJzdWIiOiIxMjM0" + ".abcdefghijklmnop", "jwt"))
        list.append(("Authorization: Bearer " + "abcdef0123456789xyz", "authorization-header"))
        list.append(("curl -H 'bearer " + "abcdefghijklmnopqrstu'", "bearer-token"))
        list.append(("git clone https://deploy:" + "s3cr3tPass@example.com/repo.git", "url-credentials"))
        list.append(("password = " + "Tr0ub4dor&3x", "secret-assignment"))
        list.append(("export API_KEY=" + "abcdef123456", "secret-assignment"))
        list.append(("\"client_secret\": \"" + "9f8e7d6c5b4a\"", "secret-assignment"))
        list.append(("//registry.npmjs.org/:_authToken=" + "npm_0123456789abcdef", "secret-assignment"))
        list.append(("blob q8Zx3VbN7mKp2LrT9wYd5HfG1jCs6AeU4oPi0XnB end", "high-entropy-token"))
        return list
    }

    @Test func detectsSecrets() {
        for (sample, rule) in Self.positives() {
            #expect(SensitiveDataScanner.scan(sample).contains(rule), "missed rule \(rule)")
        }
    }

    @Test(arguments: [
        "Hotovo. Změnil jsem ContentView.swift a přidal jsem test.",
        "Spusť `swift test` a zkontroluj výstup.",
        "let token: String = fetchToken()",
        "password = getPassword()",
        "token: ${GITHUB_TOKEN}",
        "api_key = os.environ[\"API_KEY\"]",
        "secret: <your-secret-here>",
        "auth: required",
        "commit 7db6a79c3f5e1d2b8a4c6e9f0b1d3a5c7e9f2b4d byl vytvořen",
        "sha256 bbbc41bf1f632830af2beb9584801fb85bcd888f38895c5d189b6c31a10e5c8d",
        "id 3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        "/Users/mac_pavel/Library/Application Support/PureClipboard/config.json",
        "max_tokens = 4096",
        "Nastav API key v nastavení aplikace.",
    ])
    func allowsOrdinaryText(sample: String) {
        #expect(SensitiveDataScanner.scan(sample).isEmpty, "unexpected finding for: \(sample)")
    }

    @Test func findingsNeverContainTheSecret() {
        let secret = "ghp_" + String(repeating: "Zz9", count: 10)
        let findings = SensitiveDataScanner.scan("here: \(secret)")
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { !secret.contains($0) && !$0.contains(secret) })
    }

    @Test func entropyOrdering() {
        #expect(SensitiveDataScanner.shannonEntropy("aaaaaaaa") == 0)
        #expect(SensitiveDataScanner.shannonEntropy("abcdefgh") > 2.9)
    }
}
