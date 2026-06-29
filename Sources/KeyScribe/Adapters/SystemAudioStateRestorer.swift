import CoreAudio
import Foundation
import KeyScribeKit

// Crash-safe restoration of global macOS audio state KeyScribe temporarily changes during a dictation:
// the system default INPUT device (overridden to honor a preferred mic the AUHAL cannot pin) and the
// OUTPUT device's mute flag (muted during dictation). Each change is recorded to a durable marker BEFORE
// it is applied and cleared AFTER it is restored in-process; if a crash/SIGKILL/force-quit lands between
// the two, the marker survives and reconcileOnLaunch() undoes it on the next start — the gap that left
// 0.1.7's crash with a hijacked default mic. Devices are resolved by UID, never by transient AudioDeviceID.
final class SystemAudioStateRestorer: Sendable {
    private let store: PendingSystemRestoreStore

    init(store: PendingSystemRestoreStore) { self.store = store }

    // MARK: - Record / clear (called around each in-process mutation)

    func recordDefaultInputOverride(originalUID: String) {
        store.update { $0.defaultInputUID = originalUID }
    }

    func clearDefaultInputOverride() {
        store.update { $0.defaultInputUID = nil }
    }

    func recordOutputMute(deviceUID: String, previousMute: UInt32) {
        store.update { $0.outputMute = .init(deviceUID: deviceUID, previousMute: previousMute) }
    }

    func clearOutputMute() {
        store.update { $0.outputMute = nil }
    }

    // MARK: - Reconcile

    // Undo any global state recorded but not yet restored. Called at launch (to recover from a prior run
    // that crashed/was killed while dirty) and on graceful terminate (so a Cmd-Q mid-dictation restores
    // immediately rather than waiting for the next launch). Idempotent: clears the marker when done.
    func reconcile() {
        let pending = store.load()
        guard !pending.isEmpty else { return }
        if let uid = pending.defaultInputUID, let device = AudioInputDevices.deviceID(forUID: uid) {
            AudioInputDevices.setSystemDefaultInput(device)
        }
        if let mute = pending.outputMute, let device = AudioInputDevices.deviceID(forAnyUID: mute.deviceUID) {
            SystemOutputAudio.setMute(mute.previousMute, on: device)
        }
        // Clear unconditionally — even if a recorded device is absent right now (cannot be restored). A
        // stale marker must never survive to re-fire on every future launch; when that device returns the
        // user's own selection governs. We do not chase a disconnected device across launches.
        store.update { $0 = PendingSystemRestore() }
    }
}
