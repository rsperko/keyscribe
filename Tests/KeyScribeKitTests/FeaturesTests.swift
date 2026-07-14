import Foundation
import Testing
@testable import KeyScribeKit

// Covers storage behavior independent of any specific flag (absent table, unknown-id pruning,
// round-tripping) since Feature can ship with zero cases; per-flag tests live below with each case.
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

    // ids are hand-written strings keying both storage and pruning; a collision would make one flag
    // shadow another. Guards every future case as soon as it is added.
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

    // Absence already means off, so turning the flag back off carries no information and is elided.
    @Test func streamingTranscriptionOffIsElided() throws {
        var s = Settings.defaults
        s.features.setEnabled(true, for: .streamingTranscription)
        s.features.setEnabled(false, for: .streamingTranscription)
        #expect(s.features == Settings.Features())
        let toml = try SettingsStore.encode(s)
        #expect(!toml.contains("streaming_transcription"))
    }
}
