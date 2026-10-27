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
            transcript: "note hello", supportDir: try supportDir(voiceCommandsOn: true), system: system)
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
            transcript: "note hello", supportDir: try supportDir(voiceCommandsOn: false), system: system)
        #expect(status == 0)
        #expect(system.scriptRuns.isEmpty)
    }
}
