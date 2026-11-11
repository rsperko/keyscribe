import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct VoiceCommandCLITests {
    private func supportDir(voiceCommandsOn: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var settings = Settings.defaults
        settings.features.setEnabled(voiceCommandsOn, for: .voiceCommands)
        try SettingsStore.write(settings, to: dir)
        let note = VoiceCommandScript(name: "note", run: ["/bin/echo", "{text}"])
        try VoiceCommandStore.write(VoiceCommandConfig(scripts: [note]), to: dir)
        return dir
    }

    @Test func theCommandLineNeverRunsAScriptEvenWithVoiceCommandsOn() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let status = await VoiceCommandCLI.run(
            transcript: "run note hello", supportDir: try supportDir(voiceCommandsOn: true), system: system)
        #expect(status == 0)
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func theCommandLineNeverOpensAnApp() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        system.installed = [.init(name: "Mail", bundleId: "com.apple.mail")]
        let status = await VoiceCommandCLI.run(
            transcript: "open mail", supportDir: try supportDir(voiceCommandsOn: true), system: system)
        #expect(status == 0)
        #expect(system.opened.isEmpty)
        #expect(system.activatedPids.isEmpty)
    }

    @Test func aPhraseStillResolvesWhileVoiceCommandsIsOff() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let status = await VoiceCommandCLI.run(
            transcript: "run note hello", supportDir: try supportDir(voiceCommandsOn: false), system: system)
        #expect(status == 0)
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func theDryRunNamesRulesThatNeverRunAndSkipsOtherModesFiles() async throws {
        let dir = try supportDir(voiceCommandsOn: true)
        try """
        schema_version = 1
        [[rules]]
        heard = '(o+)+'
        replace = 'oh'
        regex = true
        """.write(to: dir.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try "name = \"Broken\"\nnot = [valid".write(
            to: modesDir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
        var lines: [String] = []
        _ = await VoiceCommandCLI.run(
            transcript: "run note hello", supportDir: dir, system: VoiceCommandRunnerTests.FakeSystem()) { lines.append($0) }
        let ignored = lines.filter { $0.hasPrefix("ignored:") }
        #expect(ignored.count == 1)
        #expect(ignored.first?.contains("replacements.toml") == true)
        #expect(ignored.first?.contains("(o+)+") == true)
    }

    @Test func theDryRunNamesARuleInTheVoiceCommandsModeThatNeverRuns() async throws {
        let dir = try supportDir(voiceCommandsOn: true)
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        var mode = Mode(id: Mode.voiceCommandsId, name: "Voice Commands")
        mode.replacements = .init(rules: [.init(heard: "(o+)+", replace: "oh", regex: true)])
        try ModeStore.write(mode, to: modesDir)
        var lines: [String] = []
        _ = await VoiceCommandCLI.run(
            transcript: "run note hello", supportDir: dir, system: VoiceCommandRunnerTests.FakeSystem()) { lines.append($0) }
        let ignored = lines.filter { $0.hasPrefix("ignored:") }
        #expect(ignored.count == 1)
        #expect(ignored.first?.contains("\(Mode.voiceCommandsId).toml — \u{201C}(o+)+\u{201D}") == true)
    }
}
