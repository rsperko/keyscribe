import Foundation
import Testing
@testable import KeyScribeKit

struct VoiceCommandConfigTests {
    @Test func decodesAppAndURLPlaces() throws {
        let toml = """
        schema_version = 1

        [[command]]
        name = "VS Code"
        say = ["vscode", "editor"]
        app = "com.microsoft.VSCode"

        [[command]]
        name = "Gmail"
        url = "https://mail.google.com/"
        browser = "com.google.Chrome"
        """
        let config = try VoiceCommandStore.decode(from: toml)
        #expect(config.places == [
            VoiceCommandPlace(name: "VS Code", say: ["vscode", "editor"], target: .app(bundleId: "com.microsoft.VSCode")),
            VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"), browser: "com.google.Chrome"),
        ])
    }

    @Test func absentSayFallsBackToTheName() throws {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        #expect(place.spokenForms == ["Gmail"])
        let named = VoiceCommandPlace(name: "Gmail", say: ["mail"], target: .url("https://mail.google.com/"))
        #expect(named.spokenForms == ["Gmail", "mail"])
    }

    @Test func emptyFileHasNoPlaces() throws {
        #expect(try VoiceCommandStore.decode(from: "schema_version = 1").places.isEmpty)
    }

    @Test func roundTripsThroughEncode() throws {
        let config = VoiceCommandConfig(places: [
            VoiceCommandPlace(name: "Code", say: ["vscode"], target: .app(bundleId: "com.microsoft.VSCode")),
            VoiceCommandPlace(name: "Mail", target: .url("https://mail.google.com/"), browser: "com.apple.Safari"),
        ])
        let decoded = try VoiceCommandStore.decode(from: VoiceCommandStore.encode(config))
        #expect(decoded == config)
    }

    @Test func encodedFileEndsWithANewline() throws {
        let toml = try VoiceCommandStore.encode(VoiceCommandConfig(places: [
            VoiceCommandPlace(name: "Mail", target: .url("https://mail.google.com/")),
        ]))
        #expect(toml.hasSuffix("\n"))
    }

    @Test func aMisspelledKeyIsReportedWithTheKeyItMeant() {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Gmail"
        url = "https://mail.google.com/"
        browsr = "com.google.Chrome"
        """
        #expect(VoiceCommandStore.unknownKeys(in: toml) == [UnknownConfigKey(path: "command[0].browsr", suggestion: "browser")])
    }

    @Test func everyKeyTheFileCanHoldIsRead() throws {
        let toml = try VoiceCommandStore.encode(VoiceCommandStore.everyKeyExample)
        #expect(VoiceCommandStore.unknownKeys(in: toml).isEmpty)
    }

    @Test func encodeOmitsAnEmptySayList() throws {
        let toml = try VoiceCommandStore.encode(VoiceCommandConfig(places: [
            VoiceCommandPlace(name: "Mail", target: .url("https://mail.google.com/")),
        ]))
        #expect(!toml.contains("say"))
        #expect(!toml.contains("browser"))
    }

    @Test func rejectsAPlaceWithBothTargets() {
        let toml = """
        schema_version = 1
        [[command]]
        name = "Both"
        app = "com.example.app"
        url = "https://example.com/"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func rejectsAPlaceWithNoTarget() {
        let toml = """
        schema_version = 1
        [[command]]
        name = "Nowhere"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func rejectsANonWebURL() {
        let toml = """
        schema_version = 1
        [[command]]
        name = "Files"
        url = "file:///etc/hosts"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func rejectsABlankName() {
        let toml = """
        schema_version = 1
        [[command]]
        name = "  "
        app = "com.example.app"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func rejectsAMultilineSpokenForm() {
        let toml = """
        schema_version = 1
        [[command]]
        name = "Mail"
        say = ["mail\\nbox"]
        app = "com.apple.mail"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func rejectsDuplicatePlaceNames() {
        let toml = """
        schema_version = 1
        [[command]]
        name = "Mail"
        app = "com.apple.mail"
        [[command]]
        name = "mail"
        url = "https://mail.google.com/"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func rejectsANewerSchema() {
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: "schema_version = 99") }
    }

    @Test func validationReportsTheFirstIssue() {
        #expect(VoiceCommandPlace(name: "", target: .app(bundleId: "x")).issue != nil)
        #expect(VoiceCommandPlace(name: "Ok", target: .app(bundleId: "")).issue != nil)
        #expect(VoiceCommandPlace(name: "Ok", target: .url("not a url")).issue != nil)
        #expect(VoiceCommandPlace(name: "Ok", say: [""], target: .app(bundleId: "x")).issue != nil)
        #expect(VoiceCommandPlace(name: "Ok", target: .app(bundleId: "x")).issue == nil)
    }

    @Test func loadDistinguishesAbsentFromMalformed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(VoiceCommandStore.load(supportDir: dir) == .absent)

        let config = VoiceCommandConfig(places: [VoiceCommandPlace(name: "Mail", target: .app(bundleId: "com.apple.mail"))])
        try VoiceCommandStore.write(config, to: dir)
        #expect(VoiceCommandStore.load(supportDir: dir) == .loaded(config))

        try "not toml [".write(to: dir.appendingPathComponent(VoiceCommandStore.fileName), atomically: true, encoding: .utf8)
        if case .failed = VoiceCommandStore.load(supportDir: dir) {} else { Issue.record("expected .failed") }
    }
}
