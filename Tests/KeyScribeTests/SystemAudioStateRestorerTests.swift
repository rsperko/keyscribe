import CoreAudio
import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private final class RestorerPersistence: PendingSystemRestorePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() -> Data? { lock.withLock { data } }

    func write(_ data: Data?) {
        lock.withLock { self.data = data }
    }
}

private final class AudioRestoreRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _defaultInputs: [AudioDeviceID] = []
    private var _mutes: [(value: UInt32, device: AudioDeviceID)] = []

    var defaultInputs: [AudioDeviceID] { lock.withLock { _defaultInputs } }
    var mutes: [(value: UInt32, device: AudioDeviceID)] { lock.withLock { _mutes } }

    func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        lock.withLock { _defaultInputs.append(device) }
        return true
    }

    func setMute(_ value: UInt32, on device: AudioDeviceID) -> Bool {
        lock.withLock { _mutes.append((value, device)) }
        return true
    }
}

struct SystemAudioStateRestorerTests {
    private func makeStore(_ state: PendingSystemRestore) -> PendingSystemRestoreStore {
        let store = PendingSystemRestoreStore(persistence: RestorerPersistence())
        store.update { $0 = state }
        return store
    }

    @Test func launchReconcileUnmutesOutputWhenPreviousStateWasUnmuted() {
        let recorder = AudioRestoreRecorder()
        let store = makeStore(.init(outputMute: .init(deviceUID: "out", previousMute: 0)))
        let restorer = SystemAudioStateRestorer(
            store: store,
            resolveInputDevice: { _ in nil },
            resolveAnyDevice: { $0 == "out" ? 42 : nil },
            setDefaultInput: recorder.setDefaultInput,
            setOutputMute: recorder.setMute)

        restorer.reconcile()

        #expect(recorder.mutes.count == 1)
        #expect(recorder.mutes.first?.value == 0)
        #expect(recorder.mutes.first?.device == 42)
        #expect(store.load().isEmpty)
    }

    @Test func launchReconcileUnmutesStaleOutputMarkerEvenWhenPreviousStateWasRecordedMuted() {
        let recorder = AudioRestoreRecorder()
        let store = makeStore(.init(outputMute: .init(deviceUID: "out", previousMute: 1)))
        let restorer = SystemAudioStateRestorer(
            store: store,
            resolveInputDevice: { _ in nil },
            resolveAnyDevice: { $0 == "out" ? 42 : nil },
            setDefaultInput: recorder.setDefaultInput,
            setOutputMute: recorder.setMute)

        restorer.reconcile()

        #expect(recorder.mutes.count == 1)
        #expect(recorder.mutes.first?.value == 0)
        #expect(recorder.mutes.first?.device == 42)
        #expect(store.load().isEmpty)
    }

    @Test func outputMuteMarkerIsOnlyRecordedWhenKeyScribeChangedAudibleState() {
        let store = makeStore(.init(defaultInputUID: "mic"))
        let restorer = SystemAudioStateRestorer(store: store)

        restorer.recordOutputMute(deviceUID: "out", previousMute: 1)

        #expect(store.load() == PendingSystemRestore(defaultInputUID: "mic"))
    }

    @Test func launchReconcileStillRestoresDefaultInput() {
        let recorder = AudioRestoreRecorder()
        let store = makeStore(.init(defaultInputUID: "mic"))
        let restorer = SystemAudioStateRestorer(
            store: store,
            resolveInputDevice: { $0 == "mic" ? 12 : nil },
            resolveAnyDevice: { _ in nil },
            setDefaultInput: recorder.setDefaultInput,
            setOutputMute: recorder.setMute)

        restorer.reconcile()

        #expect(recorder.defaultInputs == [12])
        #expect(store.load().isEmpty)
    }
}
