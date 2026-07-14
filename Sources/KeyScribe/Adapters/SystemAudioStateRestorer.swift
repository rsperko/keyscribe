import CoreAudio
import Foundation
import KeyScribeKit

// Legacy crash-recovery reconcile only — current builds never change the system default input and so
// never write these markers. This exists solely to undo a state a pre-fix build may have stranded on
// an earlier crash. Devices are resolved by UID, never by transient AudioDeviceID.
final class SystemAudioStateRestorer: Sendable {
    private let readMarker: @Sendable () -> Data?
    private let deleteMarker: @Sendable () -> Void
    private let resolveInputDevice: @Sendable (String) -> AudioDeviceID?
    private let resolveOutputDevice: @Sendable (String) -> AudioDeviceID?
    private let setDefaultInput: @Sendable (AudioDeviceID) -> Bool
    private let setOutputMute: @Sendable (UInt32, AudioDeviceID) -> Bool

    init(
        readMarker: @escaping @Sendable () -> Data?,
        deleteMarker: @escaping @Sendable () -> Void,
        resolveInputDevice: @escaping @Sendable (String) -> AudioDeviceID? = AudioInputDevices.deviceID(forUID:),
        resolveOutputDevice: @escaping @Sendable (String) -> AudioDeviceID? = AudioInputDevices.deviceID(forAnyUID:),
        setDefaultInput: @escaping @Sendable (AudioDeviceID) -> Bool = AudioInputDevices.setSystemDefaultInput,
        setOutputMute: @escaping @Sendable (UInt32, AudioDeviceID) -> Bool = SystemOutputAudio.setMute
    ) {
        self.readMarker = readMarker
        self.deleteMarker = deleteMarker
        self.resolveInputDevice = resolveInputDevice
        self.resolveOutputDevice = resolveOutputDevice
        self.setDefaultInput = setDefaultInput
        self.setOutputMute = setOutputMute
    }

    convenience init(markerURL: URL) {
        self.init(
            readMarker: { try? Data(contentsOf: markerURL) },
            deleteMarker: { try? FileManager.default.removeItem(at: markerURL) })
    }

    // Idempotent — safe to call on every launch.
    func reconcile() {
        guard let data = readMarker(),
              let pending = PendingSystemRestore.decode(from: data),
              !pending.isEmpty else { return }
        if let uid = pending.defaultInputUID, let device = resolveInputDevice(uid) {
            _ = setDefaultInput(device)
        }
        // Legacy mute recovery. Current builds duck output, which the OS releases on exit.
        if let uid = pending.legacyMutedOutputUID, let device = resolveOutputDevice(uid) {
            _ = setOutputMute(0, device)
        }
        // Clear even if a recorded device is absent; do not chase a disconnected device across launches.
        deleteMarker()
    }
}
