import CoreAudio
import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private final class MarkerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _deleteCount = 0

    init(_ data: Data?) { _data = data }

    var deleteCount: Int { lock.withLock { _deleteCount } }

    func read() -> Data? { lock.withLock { _data } }

    func delete() {
        lock.withLock {
            _data = nil
            _deleteCount += 1
        }
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
    @Test func launchReconcileRestoresDefaultInput() {
        let recorder = AudioRestoreRecorder()
        let box = MarkerBox(Data(#"{"defaultInputUID":"mic"}"#.utf8))
        let restorer = SystemAudioStateRestorer(
            readMarker: box.read,
            deleteMarker: box.delete,
            resolveInputDevice: { $0 == "mic" ? 12 : nil },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs == [12])
        #expect(box.read() == nil)
        #expect(box.deleteCount == 1)
    }

    // A pre-duck build could crash while output was muted; reconcile must unmute that device once on the
    // upgraded build, even with no input override (the common shape).
    @Test func launchReconcileUnmutesLegacyOutputMuteMarker() throws {
        let recorder = AudioRestoreRecorder()
        // Raw legacy bytes — a current build would never produce an `outputMute` key.
        let box = MarkerBox(Data(#"{"outputMute":{"deviceUID":"out","previousMute":0}}"#.utf8))
        let restorer = SystemAudioStateRestorer(
            readMarker: box.read,
            deleteMarker: box.delete,
            resolveInputDevice: { _ in nil },
            resolveOutputDevice: { $0 == "out" ? 42 : nil },
            setDefaultInput: recorder.setDefaultInput,
            setOutputMute: recorder.setMute)

        restorer.reconcile()

        #expect(recorder.mutes.count == 1)
        #expect(recorder.mutes.first?.value == 0)
        #expect(recorder.mutes.first?.device == 42)
        #expect(box.read() == nil)
        #expect(box.deleteCount == 1)
    }

    @Test func launchReconcileClearsMarkerEvenWhenDeviceIsAbsent() {
        let recorder = AudioRestoreRecorder()
        let box = MarkerBox(Data(#"{"defaultInputUID":"mic"}"#.utf8))
        let restorer = SystemAudioStateRestorer(
            readMarker: box.read,
            deleteMarker: box.delete,
            resolveInputDevice: { _ in nil },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs.isEmpty)
        #expect(box.read() == nil)
        #expect(box.deleteCount == 1)
    }

    // A half-written-by-a-crash marker must be left on disk, not cleared as if empty.
    @Test func reconcileLeavesUndecodableMarkerOnDisk() {
        let recorder = AudioRestoreRecorder()
        let box = MarkerBox(Data("garbage".utf8))
        let restorer = SystemAudioStateRestorer(
            readMarker: box.read,
            deleteMarker: box.delete,
            resolveInputDevice: { _ in 12 },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs.isEmpty)
        #expect(box.read() != nil)
        #expect(box.deleteCount == 0)
    }

    @Test func reconcileIgnoresAbsentMarker() {
        let recorder = AudioRestoreRecorder()
        let box = MarkerBox(nil)
        let restorer = SystemAudioStateRestorer(
            readMarker: box.read,
            deleteMarker: box.delete,
            resolveInputDevice: { _ in 12 },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs.isEmpty)
        #expect(box.deleteCount == 0)
    }

    @Test func reconcileLeavesEmptyDecodableMarker() {
        let recorder = AudioRestoreRecorder()
        let box = MarkerBox(Data("{}".utf8))
        let restorer = SystemAudioStateRestorer(
            readMarker: box.read,
            deleteMarker: box.delete,
            resolveInputDevice: { _ in 12 },
            setDefaultInput: recorder.setDefaultInput)

        restorer.reconcile()

        #expect(recorder.defaultInputs.isEmpty)
        #expect(box.deleteCount == 0)
    }
}
