import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// The preferred-device UID must reach the capture adapter both at construction and on every settings
// change — the adapter holds it standing so its idle device listener can re-resolve the effective device
// (preferred-if-present, else system default). No microphone required; the fake just records the pushes.
@MainActor
struct PreferredInputDeviceTests {
    private final class TinyEngine: SpeechEngine, @unchecked Sendable {
        let id = "tiny"
        let displayName = "Tiny"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
        func evict() async {}
    }

    private final class RecordingAudio: AudioCapturing, @unchecked Sendable {
        private let lock = NSLock()
        private var _uids: [String?] = []
        var uids: [String?] { lock.withLock { _uids } }
        func start(sampleRate: Int) async throws -> URL {
            URL(fileURLWithPath: "/dev/null")
        }
        func stop() -> URL? { nil }
        func setPreferredInputUID(_ uid: String?) { lock.withLock { _uids.append(uid) } }
    }

    private func makeController(settings: Settings, audio: AudioCapturing) -> DictationController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-pref-\(UUID().uuidString)", isDirectory: true)
        let provider = try! SpeechEngineProvider(engines: [TinyEngine()], activeId: "tiny")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: dir),
            history: nil, hud: nil, audio: audio)
    }

    @Test func preferredUIDReachesCaptureOnInit() {
        var settings = Settings.defaults
        settings.audio = .init(inputDeviceUID: "Shure-MV7")
        let audio = RecordingAudio()
        _ = makeController(settings: settings, audio: audio)
        #expect(audio.uids == ["Shure-MV7"])
    }

    @Test func systemDefaultPushesNilOnInit() {
        let audio = RecordingAudio()
        _ = makeController(settings: .defaults, audio: audio)
        #expect(audio.uids == [nil])
    }

    @Test func settingsChangeForwardsNewPreferredUID() {
        let audio = RecordingAudio()
        let controller = makeController(settings: .defaults, audio: audio)
        var changed = Settings.defaults
        changed.audio = .init(inputDeviceUID: "BuiltInMic")
        controller.updateSettings(changed)
        #expect(audio.uids == [nil, "BuiltInMic"])
    }

    @Test func microphoneStatusNamesSystemInputWhenFollowingSystemInput() {
        let text = SettingsModel.microphoneStatusText(
            inputDeviceUID: "",
            storedInputDeviceName: nil,
            liveDevices: [AudioInputDevices.Device(id: 5, uid: "BuiltInMic", name: "MacBook Pro Microphone")],
            systemDefault: AudioInputDevices.Device(id: 5, uid: "BuiltInMic", name: "MacBook Pro Microphone"))
        #expect(text == "Using macOS input: MacBook Pro Microphone.")
    }

    @Test func microphoneStatusNamesPreferredInputWhenAvailable() {
        let text = SettingsModel.microphoneStatusText(
            inputDeviceUID: "BuiltInMic",
            storedInputDeviceName: "MacBook Pro Microphone",
            liveDevices: [
                AudioInputDevices.Device(id: 5, uid: "BuiltInMic", name: "MacBook Pro Microphone"),
                AudioInputDevices.Device(id: 7, uid: "Bose", name: "Bose QC Ultra 2 HP"),
            ],
            systemDefault: AudioInputDevices.Device(id: 7, uid: "Bose", name: "Bose QC Ultra 2 HP"))
        #expect(text == "Preferred: MacBook Pro Microphone. macOS input is Bose QC Ultra 2 HP.")
    }

    @Test func microphoneStatusNamesFallbackWhenPreferredInputIsUnavailable() {
        let text = SettingsModel.microphoneStatusText(
            inputDeviceUID: "DeskMic",
            storedInputDeviceName: "Desk Mic",
            liveDevices: [AudioInputDevices.Device(id: 5, uid: "BuiltInMic", name: "MacBook Pro Microphone")],
            systemDefault: AudioInputDevices.Device(id: 5, uid: "BuiltInMic", name: "MacBook Pro Microphone"))
        #expect(text == "Desk Mic unavailable. Using macOS input: MacBook Pro Microphone.")
    }
}
