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

    @Test func launchReconcileRestoresDefaultInput() {
        let recorder = AudioRestoreRecorder()
        let store = makeStore(.init(defaultInputUID: "mic"))
        let restorer = SystemAudioStateRestorer(
            store: store,
            resolveInputDevice: { $0 == "mic" ? 12 : nil },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs == [12])
        #expect(store.load().isEmpty)
    }

    // A pre-duck build could crash while output was muted; reconcile must unmute that device once on the
    // upgraded build and clear the stale marker, even when there was no input override (the common shape).
    @Test func launchReconcileUnmutesLegacyOutputMuteMarker() throws {
        let recorder = AudioRestoreRecorder()
        // Seed the raw legacy bytes directly — a current encode would never produce an `outputMute` key.
        let persistence = RestorerPersistence()
        persistence.write(Data(#"{"outputMute":{"deviceUID":"out","previousMute":0}}"#.utf8))
        let store = PendingSystemRestoreStore(persistence: persistence)
        let restorer = SystemAudioStateRestorer(
            store: store,
            resolveInputDevice: { _ in nil },
            resolveOutputDevice: { $0 == "out" ? 42 : nil },
            setDefaultInput: recorder.setDefaultInput,
            setOutputMute: recorder.setMute)

        restorer.reconcile()

        #expect(recorder.mutes.count == 1)
        #expect(recorder.mutes.first?.value == 0)
        #expect(recorder.mutes.first?.device == 42)
        #expect(store.load().isEmpty)
    }

    @Test func launchReconcileClearsMarkerEvenWhenDeviceIsAbsent() {
        let recorder = AudioRestoreRecorder()
        let store = makeStore(.init(defaultInputUID: "mic"))
        let restorer = SystemAudioStateRestorer(
            store: store,
            resolveInputDevice: { _ in nil },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs.isEmpty)
        #expect(store.load().isEmpty)
    }
}
