import Foundation
import Testing
@testable import KeyScribeKit

// Covers storage behavior independent of any specific flag (absent table, unknown and retired ids,
// round-tripping) since Feature can ship with zero cases; per-flag tests live below with each case.
struct FeaturesTests {
    @Test func absentFeaturesTableDecodesToNoOverrides() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        #expect(s.features == Settings.Features())
        #expect(s == Settings.defaults)
    }

    @Test func aFlagFromANewerVersionSurvivesASave() throws {
        let toml = """
        schema_version = 1
        [features]
        not_a_real_flag = true
        another_ghost = false
        """
        let s = try SettingsStore.decode(from: toml)
        #expect(Feature.allCases.allSatisfy { !s.features.isSwitchedOn($0) })
        let reencoded = try SettingsStore.encode(s)
        #expect(reencoded.contains("not_a_real_flag = true"))
        #expect(!reencoded.contains("another_ghost"))
    }

    @Test func aFlagFromANewerVersionIsNotReportedAsAnUnknownKey() {
        #expect(SettingsStore.unknownKeys(in: "schema_version = 1\n[features]\nnot_a_real_flag = true").isEmpty)
    }

    @Test func turningAKnownFlagOnKeepsANewerVersionsFlag() throws {
        var s = try SettingsStore.decode(from: "schema_version = 1\n[features]\nnot_a_real_flag = true")
        s.features.setEnabled(true, for: .voiceCommands)
        let reencoded = try SettingsStore.encode(s)
        #expect(reencoded.contains("not_a_real_flag = true"))
        #expect(reencoded.contains("voice_commands = true"))
    }

    @Test func defaultsRoundTripPreservesEmptyFeatures() throws {
        let decoded = try SettingsStore.decode(from: SettingsStore.encode(Settings.defaults))
        #expect(decoded.features == Settings.defaults.features)
    }

    @Test func constructorKeepsUnknownOverrides() {
        #expect(Settings.Features(overrides: ["ghost": true]) != Settings.Features())
    }

    @Test func retiredIdsAreDropped() {
        for id in Feature.retiredIds {
            #expect(Settings.Features(overrides: [id: true]) == Settings.Features())
        }
    }

    @Test func noLiveFlagIsRetired() {
        #expect(Feature.retiredIds.isDisjoint(with: Feature.allCases.map(\.id)))
    }

    @Test func offOverridesArePruned() {
        #expect(Settings.Features(overrides: ["not_a_real_flag": false]) == Settings.Features())
    }

    @Test func featureIdsAreUnique() {
        let ids = Feature.allCases.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func streamingTranscriptionDefaultsOff() {
        #expect(!Settings.defaults.features.isEnabled(.streamingTranscription))
    }

    @Test func streamingTranscriptionOverridePersists() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .streamingTranscription)
        let toml = try SettingsStore.encode(s)
        #expect(toml.contains("streaming_transcription = true"))
        let decoded = try SettingsStore.decode(from: toml)
        #expect(decoded.features.isEnabled(.streamingTranscription))
    }

    @Test func consumptionDrivenRestoreDefaultsOff() {
        #expect(!Settings.defaults.features.isEnabled(.consumptionDrivenRestore))
    }

    @Test func consumptionDrivenRestoreOverridePersists() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .consumptionDrivenRestore)
        let toml = try SettingsStore.encode(s)
        #expect(toml.contains("consumption_driven_restore = true"))
        let decoded = try SettingsStore.decode(from: toml)
        #expect(decoded.features.isEnabled(.consumptionDrivenRestore))
    }

    @Test func consumptionDrivenRestoreOffIsElided() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .consumptionDrivenRestore)
        s.features.setEnabled(false, for: .consumptionDrivenRestore)
        #expect(s.features == Settings.Features())
        #expect(try !SettingsStore.encode(s).contains("consumption_driven_restore"))
    }

    @Test func streamingTranscriptionOffIsElided() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .streamingTranscription)
        s.features.setEnabled(false, for: .streamingTranscription)
        #expect(s.features == Settings.Features())
        let toml = try SettingsStore.encode(s)
        #expect(!toml.contains("streaming_transcription"))
    }

    @Test func voiceCommandsDefaultsOff() {
        #expect(!Settings.defaults.features.isEnabled(.voiceCommands))
    }

    @Test func voiceCommandsOverridePersists() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .voiceCommands)
        let toml = try SettingsStore.encode(s)
        #expect(toml.contains("voice_commands = true"))
        let decoded = try SettingsStore.decode(from: toml)
        #expect(decoded.features.isEnabled(.voiceCommands))
    }

    @Test func findInAppsDefaultsOff() {
        #expect(!Settings.defaults.features.isEnabled(.findInApps))
    }

    @Test func findInAppsIsNestedUnderVoiceCommands() {
        #expect(Feature.findInApps.requires == .voiceCommands)
        #expect(Feature.voiceCommands.dependents == [.findInApps])
        #expect(Feature.voiceCommands.requires == nil)
        #expect(!Feature.topLevel.contains(.findInApps))
        #expect(Feature.topLevel.contains(.voiceCommands))
    }

    @Test func everyRequirementIsAnotherTopLevelFeature() {
        for feature in Feature.allCases {
            guard let parent = feature.requires else { continue }
            #expect(parent != feature)
            #expect(Feature.topLevel.contains(parent))
        }
        #expect(Set(Feature.topLevel + Feature.topLevel.flatMap(\.dependents)) == Set(Feature.allCases))
    }

    @Test func findInAppsOverridePersists() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .findInApps)
        let toml = try SettingsStore.encode(s)
        #expect(toml.contains("voice_command_sidebars = true"))
        #expect(try SettingsStore.decode(from: toml).features.isSwitchedOn(.findInApps))
    }

    @Test func aNestedFeatureIsOffWhileTheFeatureItRequiresIsOff() {
        var features = Settings.Features()
        features.setEnabled(true, for: .findInApps)
        #expect(!features.isEnabled(.findInApps))
        #expect(features.isSwitchedOn(.findInApps))
        features.setEnabled(true, for: .voiceCommands)
        #expect(features.isEnabled(.findInApps))
    }

    @Test func findInAppsOffIsElided() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .findInApps)
        s.features.setEnabled(false, for: .findInApps)
        #expect(s.features == Settings.Features())
        #expect(try !SettingsStore.encode(s).contains("voice_command_sidebars"))
    }

    @Test func voiceCommandsOffIsElided() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .voiceCommands)
        s.features.setEnabled(false, for: .voiceCommands)
        #expect(s.features == Settings.Features())
        #expect(try !SettingsStore.encode(s).contains("voice_commands"))
    }
}
