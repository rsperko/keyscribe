import Foundation
import Testing
@testable import KeyScribeKit

// Feature ships with zero cases (the empty seam), so these cover the storage behavior that must hold
// independent of any specific flag: absent table, unknown-id pruning, and round-tripping. Per-flag
// default-fallback and override tests are added alongside the first real Feature case.
struct FeaturesTests {
    @Test func absentFeaturesTableDecodesToNoOverrides() throws {
        let s = try SettingsStore.decode(from: "schema_version = 1")
        #expect(s.features == Settings.Features())
        #expect(s == Settings.defaults)
    }

    @Test func unknownFeatureIdsArePrunedOnDecode() throws {
        let toml = """
        schema_version = 1
        [features]
        not_a_real_flag = true
        another_ghost = false
        """
        let s = try SettingsStore.decode(from: toml)
        #expect(s.features == Settings.Features())
    }

    @Test func unknownFeatureIdsAreDroppedOnReencode() throws {
        let toml = "schema_version = 1\n[features]\nnot_a_real_flag = true\n"
        let reencoded = try SettingsStore.encode(SettingsStore.decode(from: toml))
        #expect(!reencoded.contains("not_a_real_flag"))
    }

    @Test func defaultsRoundTripPreservesEmptyFeatures() throws {
        let decoded = try SettingsStore.decode(from: SettingsStore.encode(Settings.defaults))
        #expect(decoded.features == Settings.defaults.features)
    }

    @Test func constructorPrunesUnknownOverrides() {
        #expect(Settings.Features(overrides: ["ghost": true]) == Settings.Features())
    }

    // Off deviations carry no information — absence already means off — so they must not persist.
    @Test func offOverridesArePruned() {
        #expect(Settings.Features(overrides: ["not_a_real_flag": false]) == Settings.Features())
    }

    // ids are hand-written strings that key both storage and pruning; a collision would make one flag
    // shadow another and trap the UI's state build. Guards every future case as soon as it is added.
    @Test func featureIdsAreUnique() {
        let ids = Feature.allCases.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    // P3-1 streaming flag: strictly opt-in, so it is off unless the user turns it on.
    @Test func streamingTranscriptionDefaultsOff() {
        #expect(!Settings.defaults.features.isEnabled(.streamingTranscription))
    }

    // An on deviation persists across an encode/decode round trip and lands in the [features] table.
    @Test func streamingTranscriptionOverridePersists() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .streamingTranscription)
        let toml = try SettingsStore.encode(s)
        #expect(toml.contains("streaming_transcription = true"))
        let decoded = try SettingsStore.decode(from: toml)
        #expect(decoded.features.isEnabled(.streamingTranscription))
    }

    // Turning the flag back off carries no information (absent already means off), so it is elided.
    @Test func streamingTranscriptionOffIsElided() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .streamingTranscription)
        s.features.setEnabled(false, for: .streamingTranscription)
        #expect(s.features == Settings.Features())
        let toml = try SettingsStore.encode(s)
        #expect(!toml.contains("streaming_transcription"))
    }
}
