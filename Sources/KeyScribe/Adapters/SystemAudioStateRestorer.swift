import CoreAudio
import Foundation
import KeyScribeKit

// Legacy crash-recovery reconcile only. Current builds do not write these markers, but an upgrade may find
// one from an earlier build that changed global audio state and crashed before restoring it. Devices are
// resolved by UID, never by transient AudioDeviceID.
final class SystemAudioStateRestorer: Sendable {
    private let store: PendingSystemRestoreStore
    private let resolveInputDevice: @Sendable (String) -> AudioDeviceID?
    private let resolveOutputDevice: @Sendable (String) -> AudioDeviceID?
    private let setDefaultInput: @Sendable (AudioDeviceID) -> Bool
    private let setOutputMute: @Sendable (UInt32, AudioDeviceID) -> Bool

    init(
        store: PendingSystemRestoreStore,
        resolveInputDevice: @escaping @Sendable (String) -> AudioDeviceID? = AudioInputDevices.deviceID(forUID:),
        resolveOutputDevice: @escaping @Sendable (String) -> AudioDeviceID? = AudioInputDevices.deviceID(forAnyUID:),
        setDefaultInput: @escaping @Sendable (AudioDeviceID) -> Bool = AudioInputDevices.setSystemDefaultInput,
        setOutputMute: @escaping @Sendable (UInt32, AudioDeviceID) -> Bool = SystemOutputAudio.setMute
    ) {
        self.store = store
        self.resolveInputDevice = resolveInputDevice
        self.resolveOutputDevice = resolveOutputDevice
        self.setDefaultInput = setDefaultInput
        self.setOutputMute = setOutputMute
    }

    // MARK: - Reconcile

    // Undo any recorded global audio state and clear the marker. Idempotent.
    func reconcile() {
        let pending = store.load()
        guard !pending.isEmpty else { return }
        if let uid = pending.defaultInputUID, let device = resolveInputDevice(uid) {
            _ = setDefaultInput(device)
        }
        // Legacy mute recovery. Current builds duck output, which the OS releases on exit.
        if let uid = pending.legacyMutedOutputUID, let device = resolveOutputDevice(uid) {
            _ = setOutputMute(0, device)
        }
        // Clear even if a recorded device is absent; do not chase a disconnected device across launches.
        store.update { $0 = PendingSystemRestore() }
    }
}
