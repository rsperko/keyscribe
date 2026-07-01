import CoreAudio
import Foundation
import KeyScribeKit

// Legacy crash-recovery reconcile ONLY. Current builds never change global macOS audio state during a
// dictation: capture pins the chosen device on a raw AUHAL unit (HALInputUnit) with no system-default
// change, and output silencing uses process-scoped ducking the OS releases on exit. This type exists so a
// user UPGRADING from a flip-era build that crashed while it had overridden the system default input (the
// old 0.1.7-class strand: a hijacked default mic) has that marker undone once on the next launch. It is
// never written by this build — reconcile() reads any surviving marker, restores it, and clears it.
// Devices are resolved by UID, never by transient AudioDeviceID.
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

    // Undo any global state recorded but not yet restored. Called at launch (to recover from a prior run
    // that crashed/was killed while dirty) and on graceful terminate (so a Cmd-Q mid-dictation restores
    // immediately rather than waiting for the next launch). Idempotent: clears the marker when done.
    func reconcile() {
        let pending = store.load()
        guard !pending.isEmpty else { return }
        if let uid = pending.defaultInputUID, let device = resolveInputDevice(uid) {
            _ = setDefaultInput(device)
        }
        // Legacy: an older (pre-duck) build could have crashed while output was muted. Unmute that device
        // once so an upgrade does not leave the user stranded muted with no recovery path. Current builds
        // never write this — they duck, which the OS releases on exit.
        if let uid = pending.legacyMutedOutputUID, let device = resolveOutputDevice(uid) {
            _ = setOutputMute(0, device)
        }
        // Clear unconditionally — even if a recorded device is absent right now (cannot be restored). A
        // stale marker must never survive to re-fire on every future launch; when that device returns the
        // user's own selection governs. We do not chase a disconnected device across launches.
        store.update { $0 = PendingSystemRestore() }
    }
}
