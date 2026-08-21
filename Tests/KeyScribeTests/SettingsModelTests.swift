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
