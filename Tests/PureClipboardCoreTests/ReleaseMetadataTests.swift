import Foundation
import Testing
@testable import PureClipboardCore

/// Guards the facts the distribution documents and scripts rely on.
private func repoFile(_ relative: String, file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(relative)
}

private func plist() throws -> [String: Any] {
    let data = try Data(contentsOf: repoFile("Resources/Info.plist"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

private func text(_ relative: String) throws -> String {
    try String(contentsOf: repoFile(relative), encoding: .utf8)
}

private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Suite struct ReleaseMetadataTests {
    @Test func bundleIdentityIsStable() throws {
        let info = try plist()
        #expect(info["CFBundleIdentifier"] as? String == "studio.pure.clipboard")
        #expect(info["CFBundleExecutable"] as? String == "PureClipboard")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
    }

    @Test func versionIsSemanticAndMatchesTheCode() throws {
        let info = try plist()
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(version == PureClipboardVersion.string)
        #expect(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
        let build = try #require(Int(info["CFBundleVersion"] as? String ?? ""))
        #expect(build >= 1)
    }

    @Test func minimumSystemMatchesThePackage() throws {
        #expect(try plist()["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(try text("Package.swift").contains(".macOS(.v14)"))
    }

    @Test func iconIsReferencedAndValid() throws {
        let info = try plist()
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
        let icon = try Data(contentsOf: repoFile("Resources/AppIcon.icns"))
        #expect(icon.count > 10_000)
        #expect(String(decoding: icon.prefix(4), as: UTF8.self) == "icns")
        #expect(FileManager.default.fileExists(atPath: repoFile("docs/assets/AppIcon-1024.png").path))
    }

    @Test func storeMetadataIsPresent() throws {
        let info = try plist()
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.productivity")
        #expect((info["NSHumanReadableCopyright"] as? String)?.contains("PureStudio") == true)
    }

    @Test func buildArtifactsAreNeverCommitted() throws {
        let ignore = try text(".gitignore")
        for entry in [".build/", "build/", "dist/"] { #expect(ignore.contains(entry)) }
    }

    @Test(arguments: ["scripts/build-app.sh", "scripts/make-dmg.sh", "scripts/notarize.sh", "scripts/integration-test.sh"])
    func scriptsAreExecutableAndValidZsh(path: String) throws {
        let url = repoFile(path)
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        let result = try run("/bin/zsh", ["-n", url.path])
        #expect(result.status == 0, "\(result.out)")
    }

    @Test func notarizationRefusesAdHocOrUnsignedFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pc-notarize-\(UUID().uuidString).dmg")
        try Data("not a real disk image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try run("/bin/zsh", [repoFile("scripts/notarize.sh").path, file.path, "--submit"])
        #expect(result.status == 3)
        #expect(result.out.contains("Developer ID"))
        let plan = try run("/bin/zsh", [repoFile("scripts/notarize.sh").path, file.path])
        #expect(plan.status == 0 && plan.out.contains("nic nebylo odesláno"))
    }

    @Test func dmgScriptDoesNothingWithoutCreateFlag() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pc-dmg-\(UUID().uuidString)")
        let app = work.appendingPathComponent("PureClipboard.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.copyItem(at: repoFile("Resources/Info.plist"), to: app.appendingPathComponent("Info.plist"))
        // A real Mach-O stands in for the executable so that `lipo` and `codesign` have something to read.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: app.appendingPathComponent("MacOS/PureClipboard"))
        let dist = work.appendingPathComponent("dist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [repoFile("scripts/make-dmg.sh").path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["APP": work.appendingPathComponent("PureClipboard.app").path, "DIST_DIR": dist.path]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("Plán – nic nebylo vytvořeno"))
        #expect(!FileManager.default.fileExists(atPath: dist.path))
    }

    @Test func userDocumentsCoverTheMandatoryTopics() throws {
        let guide = try text("docs/INSTALACE.md")
        for needle in ["shasum -a 256", "Applications", "Gatekeeper", "Přesto otevřít", "notarizovaný", "Intel", "Odinstalace"] {
            #expect(guide.contains(needle), "INSTALACE.md: \(needle)")
        }
        let web = try text("docs/WEB-PURESTUDIO.md")
        for needle in ["{{SHA256}}", "ad-hoc", "není náhradou za notarizaci", "Co nepsat", "Časté otázky", "Soukromí"] {
            #expect(web.contains(needle), "WEB-PURESTUDIO.md: \(needle)")
        }
        let dist = try text("docs/DISTRIBUCE.md")
        for needle in ["notarytool", "Developer ID", "nenahrazuje notarizaci", "Intel", "studio.pure.clipboard"] {
            #expect(dist.contains(needle), "DISTRIBUCE.md: \(needle)")
        }
    }

    @Test func publicTextsDoNotOverpromise() throws {
        let web = try text("docs/WEB-PURESTUDIO.md")
        // The only place allowed to mention unsupported things is the “what not to write” list and honest caveats.
        let marketing = web.components(separatedBy: "## Co nepsat").first ?? web
        #expect(!marketing.localizedCaseInsensitiveContains("notarizovaná aplikace"))
        #expect(!marketing.contains("ověřená Applem"))
        #expect(!marketing.localizedCaseInsensitiveContains("zdarma"))
    }
}

@Suite struct Milestone5ReleaseTests {
    @Test func changelogAndDocsMatchTheCurrentVersion() throws {
        #expect(try text("CHANGELOG.md").contains("## \(PureClipboardVersion.string)"))
        let history = try text("docs/HISTORIE.md")
        #expect(history.contains("Ve výchozím stavu vypnuto") && history.contains("OCR nenajde všechno"))
    }

    @Test func webPackageHasNoWorkingDownloadLinkYet() throws {
        for lang in ["cs", "en"] {
            let page = try text("web/pure-clipboard/\(lang)/index.html")
            #expect(!page.contains(".dmg\""), "stránka \(lang) nesmí odkazovat na DMG před finálním vydáním")
            #expect(page.contains("aria-disabled=\"true\""))
        }
    }

    @Test func dmgScriptLabelsAdHocBuildsAndDoesNotClaimNotarizationForSignedOnes() throws {
        let script = try text("scripts/make-dmg.sh")
        #expect(script.contains("adhoc-TEST") && script.contains("if (( ADHOC ))"))
        // The "not notarized" wording exists only inside the ad-hoc branches.
        let signedBranch = try #require(script.components(separatedBy: "else\n  cat > \"$STAGE/PŘEČTĚTE.txt\"").dropFirst().first)
        #expect(!signedBranch.prefix(400).contains("notarizovan"))
        #expect(try text("scripts/notarize.sh").contains(".sha256"))
    }
}
