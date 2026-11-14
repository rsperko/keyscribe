import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct ConfigCheckTests {
    private func supportDir(modes: [String: String] = [:], connections: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-check-\(UUID().uuidString)")
        let modesDir = dir.appendingPathComponent("modes")
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        for (id, toml) in modes {
            try toml.write(to: modesDir.appendingPathComponent("\(id).toml"), atomically: true, encoding: .utf8)
        }
        if let connections {
            try connections.write(to: dir.appendingPathComponent(ConnectionStore.fileName), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func run(_ dir: URL) -> (status: Int32, lines: [String]) {
        var lines: [String] = []
        let status = ConfigCheck.run(supportDir: dir) { lines.append($0) }
        return (status, lines)
    }

    private let commitMode = """
        schema_version = 2
        name = "Commit message"
        enabled = true
        trigger_phrases = ["commit message"]
        """

    @Test func aCleanFolderPasses() throws {
        let result = run(try supportDir(modes: ["commit-message": commitMode]))
        #expect(result.status == 0)
        #expect(result.lines == ["OK"])
    }

    @Test func aModeThatDoesNotParseFailsAndNamesTheFileOnce() throws {
        let result = run(try supportDir(modes: ["broken": "schema_version = 2\nname = \"Broken\n"]))
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.hasPrefix("Couldn’t read modes/broken.toml") })
        #expect(!result.lines.contains { $0.contains("broken.toml: ") })
    }

    @Test func aMissingFolderFails() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-none-\(UUID().uuidString)")
        let result = run(missing)
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains(missing.path) })
    }

    @Test func aTriggerPhraseThatCannotMatchFails() throws {
        let result = run(try supportDir(modes: ["commit-message": commitMode.replacingOccurrences(of: "[\"commit message\"]", with: "[\"[\"]")]))
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains("modes/commit-message.toml") && $0.contains("trigger_phrases") })
    }

    @Test func twoModesOnTheSameShortcutFail() throws {
        let key = "\n[[trigger_keys]]\nkey = \"f12\"\npress_style = \"hold-or-tap\"\n"
        let result = run(try supportDir(modes: ["first": commitMode + key, "second": commitMode + key]))
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains("modes/second.toml") && $0.contains("f12") })
    }

    @Test func aVoiceCommandsShortcutAnotherModeUsesFails() throws {
        let key = "\n[[trigger_keys]]\nkey = \"f12\"\npress_style = \"hold-or-tap\"\n"
        let dir = try supportDir(modes: [
            Mode.voiceCommandsId: "schema_version = 2\nname = \"Voice Commands\"\nenabled = true\n" + key,
            "commit-message": commitMode + key,
        ])
        var settings = Settings.defaults
        settings.features.setEnabled(true, for: .voiceCommands)
        try SettingsStore.write(settings, to: dir)
        let result = run(dir)
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains("modes/\(Mode.voiceCommandsId).toml") && $0.contains("f12") })
    }

    @Test func aShortcutPressedOnTheWayIntoAnotherPasses() throws {
        func key(_ k: String) -> String { "\n[[trigger_keys]]\nkey = \"\(k)\"\npress_style = \"hold-or-tap\"\n" }
        let result = run(try supportDir(modes: [
            "single": commitMode + key("right_option"), "chord": commitMode + key("right_option+right_command"),
        ]))
        #expect(result.lines == ["OK"])
    }

    @Test func aBrokenModeWithARecoveryCopySaysThePreviousVersionIsStillInUse() throws {
        let dir = try supportDir(modes: ["commit-message": "schema_version = 2\nname = \"Broken\n"])
        let lkg = dir.appendingPathComponent("lkg/modes")
        try FileManager.default.createDirectory(at: lkg, withIntermediateDirectories: true)
        try commitMode.write(to: lkg.appendingPathComponent("commit-message.toml"), atomically: true, encoding: .utf8)
        let result = run(dir)
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains("modes/commit-message.toml") && $0.contains("previous version still in use") })
    }

    @Test func aMisspelledKeyFails() throws {
        let result = run(try supportDir(modes: ["commit-message": commitMode + "\ntrigger_phrase = [\"commit\"]\n"]))
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains("trigger_phrase") })
    }

    @Test func aModeWiredToAMissingConnectionFails() throws {
        let mode = commitMode + """

            [ai_rewrite]
            connection = "nowhere"
            prompt = "Format this as a git commit message."
            """
        let result = run(try supportDir(modes: ["commit-message": mode]))
        #expect(result.status != 0)
        #expect(result.lines.contains { $0.contains("modes/commit-message.toml") && $0.contains("nowhere") })
    }

    @Test func aDisabledModeWithoutAConnectionPassesLikeInTheApp() throws {
        let mode = """
            schema_version = 2
            name = "Code"
            enabled = false

            [ai_rewrite]
            connection = ""
            prompt = "Format this as code."
            """
        let result = run(try supportDir(modes: ["code": mode]))
        #expect(result.status == 0)
        #expect(result.lines == ["OK"])
    }

    @Test func checkingWritesNothing() throws {
        let dir = try supportDir(modes: ["commit-message": commitMode])
        let before = Set(try FileManager.default.subpathsOfDirectory(atPath: dir.path))
        _ = run(dir)
        let after = Set(try FileManager.default.subpathsOfDirectory(atPath: dir.path))
        #expect(after.subtracting(before).isEmpty, "check created \(after.subtracting(before).sorted())")
    }
}
