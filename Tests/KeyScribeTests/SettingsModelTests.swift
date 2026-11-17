import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct SettingsModelTests {
    private func model(
        _ settings: Settings = .defaults, onChange: @escaping (Settings) -> Void
    ) -> SettingsModel {
        SettingsModel(
            settings: settings, onChange: onChange, onReload: {}, onResetHUDPosition: {})
    }

    @Test func pickingAnOtherAudioBehaviorPersistsImmediately() {
        var saved: [OtherAudio] = []
        let model = model { saved.append($0.duringDictation.otherAudio) }

        model.otherAudio = .mute
        model.otherAudio = .unchanged

        #expect(saved == [.mute, .unchanged])
    }

    @Test func pickingAHUDAppearancePersistsImmediately() {
        var saved: [HUDAppearance] = []
        let model = model { saved.append($0.hud.appearance) }

        model.hudAppearance = .opposite

        #expect(saved == [.opposite])
    }

    @Test func applyingSettingsLoadsTheHUDAppearance() {
        let model = model { _ in }
        var incoming = Settings.defaults
        incoming.hud.appearance = .light
        model.apply(incoming)

        #expect(model.hudAppearance == .light)
    }

    @Test func turningOnBetaUpdatesPersistsImmediately() {
        var saved: [Bool] = []
        let model = model { saved.append($0.updates.beta) }

        model.betaUpdates = true
        model.betaUpdates = false

        #expect(saved == [true, false])
    }

    @Test func applyingSettingsLoadsBetaUpdates() {
        let model = model { _ in }
        var incoming = Settings.defaults
        incoming.updates.beta = true
        model.apply(incoming)

        #expect(model.betaUpdates)
    }

    @Test func savingFromSettingsKeepsAFlagANewerVersionTurnedOn() throws {
        var saved: [Settings] = []
        let start = try SettingsStore.decode(from: "schema_version = 1\n[features]\nnot_a_real_flag = true")
        let model = model(start) { saved.append($0) }

        model.binding(for: .consumptionDrivenRestore).wrappedValue = true
        model.hudAppearance = .dark

        let last = try #require(saved.last)
        let toml = try SettingsStore.encode(last)
        #expect(toml.contains("not_a_real_flag = true"))
        #expect(toml.contains("consumption_driven_restore = true"))
    }

    @Test func loadingSettingsIntoTheModelDoesNotWriteBack() {
        var writes = 0
        let model = model { _ in writes += 1 }

        var incoming = Settings.defaults
        incoming.duringDictation.otherAudio = .mute
        model.apply(incoming)

        #expect(model.otherAudio == .mute)
        #expect(writes == 0)
    }
}
