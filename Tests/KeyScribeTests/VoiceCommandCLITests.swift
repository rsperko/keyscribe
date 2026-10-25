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

    @Test func aCommandDoesNotRunWhileVoiceCommandsIsOff() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let status = await VoiceCommandCLI.run(
            transcript: "note hello", dryRun: false, supportDir: try supportDir(voiceCommandsOn: false), system: system)
        #expect(status != 0)
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func aCommandReadsNothingWhileVoiceCommandsIsOff() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let status = await VoiceCommandCLI.run(
            transcript: "switch to gmail", dryRun: false, supportDir: try supportDir(voiceCommandsOn: false), system: system)
        #expect(status != 0)
        #expect(system.tabReads.isEmpty)
        #expect(system.installedScans == 0)
    }

    @Test func missingSettingsMeanVoiceCommandsIsOff() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-cli-\(UUID().uuidString)")
        #expect(VoiceCommandCLI.refusal(supportDir: dir)?.contains("turned off") == true)
    }

    @Test func brokenSettingsAreReportedAsTheReason() throws {
        let dir = try supportDir(voiceCommandsOn: true)
        try "schema_version = 1\n[features\n".write(
            to: dir.appendingPathComponent(SettingsStore.fileName), atomically: true, encoding: .utf8)
        let refusal = try #require(VoiceCommandCLI.refusal(supportDir: dir))
        #expect(refusal.contains(SettingsStore.fileName))
        #expect(!refusal.contains("turned off"))
    }

    @Test func aDryRunStillResolvesWhileVoiceCommandsIsOff() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let status = await VoiceCommandCLI.run(
            transcript: "note hello", dryRun: true, supportDir: try supportDir(voiceCommandsOn: false), system: system)
        #expect(status == 0)
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func aCommandRunsWhileVoiceCommandsIsOn() async throws {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let status = await VoiceCommandCLI.run(
            transcript: "note hello", dryRun: false, supportDir: try supportDir(voiceCommandsOn: true), system: system)
        #expect(status == 0)
        #expect(system.scriptRuns.map(\.arguments) == [["hello"]])
    }
}
