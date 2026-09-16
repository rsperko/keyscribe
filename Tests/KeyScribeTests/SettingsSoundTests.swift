import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct SettingsSoundTests {
    private func makeModel(
        onChange: @escaping (Settings) -> Void = { _ in },
        onPreviewSound: @escaping (Int) -> Void = { _ in }
    ) -> SettingsModel {
        SettingsModel(
            settings: .defaults,
            onChange: onChange,
            onReload: {},
            onResetHUDPosition: {},
            onPreviewSound: onPreviewSound)
    }

    @Test func previewUsesCurrentCueVolume() {
        var previewedVolumes: [Int] = []
        let model = makeModel(onPreviewSound: { previewedVolumes.append($0) })

        model.soundVolume = 0.35
        model.previewSound()

        #expect(previewedVolumes == [35])
    }

    @Test func draggingTheVolumeSliderPersistsOnceOnRelease() {
        var written: [Int] = []
        var previewedVolumes: [Int] = []
        let model = makeModel(
            onChange: { written.append($0.duringDictation.soundVolumePercent) },
            onPreviewSound: { previewedVolumes.append($0) })

        model.soundVolumeEditingChanged(true)
        for tick in stride(from: 0.9, through: 0.4, by: -0.1) { model.soundVolume = tick }

        #expect(written.isEmpty)
        #expect(previewedVolumes.isEmpty)

        model.soundVolumeEditingChanged(false)

        #expect(written == [40])
        #expect(previewedVolumes == [40])
    }

    @Test func aDragThatNeverEndsDoesNotBlockOtherSettings() {
        var written: [(awake: Bool, volume: Int)] = []
        let model = makeModel(onChange: {
            written.append(($0.duringDictation.keepDisplayAwake, $0.duringDictation.soundVolumePercent))
        })

        model.soundVolumeEditingChanged(true)
        model.soundVolume = 0.6
        #expect(written.isEmpty)

        model.keepDisplayAwake = false

        #expect(written.count == 1)
        #expect(written[0].awake == false)
        #expect(written[0].volume == 60)
    }
}
