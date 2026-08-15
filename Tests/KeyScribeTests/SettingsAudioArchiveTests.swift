import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

// `keep_captures` / `keep_captures_max_mb` have no Settings UI — they are hand-edited in settings.toml.
// persist() rebuilds every table it owns from its own published fields, so any table it reconstructs
// wholesale silently drops the keys the UI does not model. These pin that the audio table keeps the two
// fields the UI never sees, whatever else the user changes.
@MainActor
struct SettingsAudioArchiveTests {
    private func makeModel(
        settings: Settings, onChange: @escaping (Settings) -> Void
    ) -> SettingsModel {
        SettingsModel(
            settings: settings, onChange: onChange, onReload: {}, onResetHUDPosition: {})
    }

    private var archivingSettings: Settings {
        var s = Settings.defaults
        s.audio = .init(
            inputDeviceUID: "BuiltInMic", inputDeviceName: "Built-in Microphone",
            keepCaptures: true, keepCapturesMaxMB: 64)
        return s
    }

    @Test func changingAnUnrelatedSettingKeepsTheCaptureArchiveConfigured() {
        var written: [Settings] = []
        let model = makeModel(settings: archivingSettings, onChange: { written.append($0) })

        model.keepDisplayAwake = false

        #expect(written.count == 1)
        #expect(written[0].audio.keepCaptures)
        #expect(written[0].audio.keepCapturesMaxMB == 64)
    }

    @Test func changingTheInputDeviceKeepsTheCaptureArchiveConfigured() {
        var written: [Settings] = []
        let model = makeModel(settings: archivingSettings, onChange: { written.append($0) })

        model.inputDeviceUID = ""

        #expect(written.count == 1)
        #expect(written[0].audio.keepCaptures)
        #expect(written[0].audio.keepCapturesMaxMB == 64)
        #expect(written[0].audio.inputDeviceUID == nil)
        #expect(written[0].audio.inputDeviceName == nil)
    }
}
