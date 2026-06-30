import CoreAudio
import Foundation
import KeyScribeKit

// Crash-safe restoration of global macOS audio state KeyScribe temporarily changes during a dictation:
// the system default INPUT device (overridden to honor a preferred mic the AUHAL cannot pin). The change
// is recorded to a durable marker BEFORE it is applied and cleared AFTER it is restored in-process; if a
// crash/SIGKILL/force-quit lands between the two, the marker survives and reconcile() undoes it on the next
// start — the gap that left 0.1.7's crash with a hijacked default mic. Devices are resolved by UID, never
// by transient AudioDeviceID. (Output silencing no longer needs a marker: it uses process-scoped ducking,
// which the OS releases automatically when our process exits — see SystemOutputAudio.duck.)
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

    // MARK: - Record / clear (called around each in-process mutation)

    func recordDefaultInputOverride(originalUID: String) {
        store.update { $0.defaultInputUID = originalUID }
    }

    func clearDefaultInputOverride() {
        store.update { $0.defaultInputUID = nil }
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
