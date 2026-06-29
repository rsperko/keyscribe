import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import KeyScribeKit

@MainActor
final class DuringDictationEffects {
    enum EndCue {
        case success
        case cancel
        case error

        var soundName: String {
            switch self {
            case .success: return "Pop"
            case .cancel: return "Bottle"
            case .error: return "Basso"
            }
        }
    }

    private var displayAssertion: IOPMAssertionID = 0
    private var hadDisplayAssertion = false
    // Every device we have muted this dictation and the value it held before — restored exactly. A
    // Bluetooth headset shifts the audible output between its A2DP and HFP instances as the mic opens, so
    // the device carrying the audio changes mid-recording; we mute each one we see become the default and
    // restore them all, never assuming a single device.
    private struct MutedEntry { let uid: String?; let device: AudioDeviceID; let previous: UInt32 }
    private var mutedEntries: [MutedEntry] = []
    private var muting = false
    private var muteFollowTask: Task<Void, Never>?
    private var generation = 0
    // Bumped on each mute start. The follow loop and restore re-apply guard on this so a later dictation's
    // mute is never clobbered by a stale task from an earlier one.
    private var muteEpoch = 0
    // Set when a dictation arms muting; the mute is applied only once capture is live (activateMute), so
    // on a Bluetooth output it lands after the A2DP->HFP route switch settles. Cleared on apply or cancel.
    private var pendingMuteGeneration: Int?
    // Records the mute to a durable marker before we apply it and clears it after we restore, so a crash
    // while muted does not leave the user's output stranded muted (reconciled on next launch).
    private let restorer: SystemAudioStateRestorer?
    private let defaultOutputDeviceID: () -> AudioDeviceID?
    private let outputMuteState: (AudioDeviceID) -> UInt32?
    private let setOutputMute: (UInt32, AudioDeviceID) -> Bool
    private let deviceUID: (AudioDeviceID) -> String?
    private let resolveOutputDevice: (String) -> AudioDeviceID?
    private let reapplyDelays: [Double]
    private let muteFollowInterval: Double

    init(
        restorer: SystemAudioStateRestorer? = nil,
        defaultOutputDeviceID: @escaping () -> AudioDeviceID? = SystemOutputAudio.defaultOutputDeviceID,
        outputMuteState: @escaping (AudioDeviceID) -> UInt32? = SystemOutputAudio.muteState,
        setOutputMute: @escaping (UInt32, AudioDeviceID) -> Bool = SystemOutputAudio.setMute,
        deviceUID: @escaping (AudioDeviceID) -> String? = AudioInputDevices.uid(of:),
        resolveOutputDevice: @escaping (String) -> AudioDeviceID? = AudioInputDevices.deviceID(forAnyUID:),
        // Span a Bluetooth route-switch settle window: an early attempt may still land mid-switch, so keep
        // re-asserting out to ~2.5s when a later one can land cleanly on the settled (A2DP) device.
        reapplyDelays: [Double] = [0.4, 1.0, 2.5],
        // While recording, re-check the default output this often and mute it if the route moved to a
        // device we have not muted yet (the Bluetooth A2DP<->HFP shift).
        muteFollowInterval: Double = 0.3
    ) {
        self.restorer = restorer
        self.defaultOutputDeviceID = defaultOutputDeviceID
        self.outputMuteState = outputMuteState
        self.setOutputMute = setOutputMute
        self.deviceUID = deviceUID
        self.resolveOutputDevice = resolveOutputDevice
        self.reapplyDelays = reapplyDelays
        self.muteFollowInterval = muteFollowInterval
    }
    // Named system sounds are reloaded by NSSound(named:) on each call; keep one instance per cue for
    // the app's lifetime so begin/end don't re-resolve them every dictation.
    private var soundCache: [String: NSSound] = [:]

    private func sound(named name: String) -> NSSound? {
        if let cached = soundCache[name] { return cached }
        let sound = NSSound(named: name)
        soundCache[name] = sound
        return sound
    }

    // First-party ~110ms cue bundled in Resources/ (NOT a system sound): short so gating capture on it
    // costs little, and original so the GPLv3 bundle ships no redistributed Apple audio. Loaded eagerly
    // (byReference: false) and cached so play() never touches disk. Absent (unbundled dev run) → no cue.
    private func startCueSound() -> NSSound? {
        if let cached = soundCache[Self.startCueKey] { return cached }
        guard let url = Bundle.main.url(forResource: "start-cue", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        soundCache[Self.startCueKey] = sound
        return sound
    }

    private static let startCueKey = "__start-cue"

    // Returns how long the caller should defer capture so the start cue stays out of the recording
    // (Option A cue gating): the cue's duration when one plays, else 0 (sounds off / cue absent → no
    // gating). The output mute follows the same deferral so muting never swallows the cue.
    @discardableResult
    func begin(_ config: Settings.DuringDictation) -> TimeInterval {
        generation &+= 1
        if config.keepDisplayAwake { acquireDisplayAssertion() }
        // Arm muting now, apply it only once capture is live (activateMute). Two reasons it must wait:
        // the start cue routes through the same output (muting first swallows it), and on a Bluetooth
        // output the device is mid A2DP->HFP route switch until capture comes up — writing the mute then
        // races the switch. Cancelled-before-capture bumps generation, so activateMute drops the mute.
        pendingMuteGeneration = config.muteSystemAudio ? generation : nil
        let startCue = config.sounds ? startCueSound() : nil
        startCue?.play()
        return startCue?.duration ?? 0
    }

    // Apply the armed mute. Called when capture goes live (the route has settled) — never from begin.
    func activateMute() {
        guard let armed = pendingMuteGeneration, armed == generation else { return }
        pendingMuteGeneration = nil
        startMuting()
    }

    // Restore the muted output as soon as capture is done, without waiting for the rest of the
    // dictation (transcription + the cloud LLM rewrite) to finish. There is no reason to keep the
    // output muted once we have stopped listening. The generation bump drops any still-pending
    // deferred mute (begin's cue-gated Task), so a sub-cue-length press can't re-mute after this.
    // restoreOutput is idempotent, so a later end(...) calling it again is a no-op.
    func restoreAudio() {
        generation &+= 1
        restoreOutput()
    }

    func end(_ config: Settings.DuringDictation, cue: EndCue = .success) {
        generation &+= 1
        pendingMuteGeneration = nil
        releaseDisplayAssertion()
        restoreOutput()
        if config.sounds { sound(named: cue.soundName)?.play() }
    }

    private func acquireDisplayAssertion() {
        guard !hadDisplayAssertion else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "\(Branding.appName) dictating" as CFString,
            &displayAssertion)
        hadDisplayAssertion = (ok == kIOReturnSuccess)
    }

    private func releaseDisplayAssertion() {
        guard hadDisplayAssertion else { return }
        IOPMAssertionRelease(displayAssertion)
        hadDisplayAssertion = false
    }

    private func startMuting() {
        guard !muting else { return }
        muting = true
        muteEpoch &+= 1
        muteCurrentDefault()
        // Follow the active output: the Bluetooth A2DP<->HFP shift moves the audible device a beat after
        // the mic opens, so poll the default and mute whatever it becomes for the life of the recording.
        let epoch = muteEpoch
        muteFollowTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(self?.muteFollowInterval ?? 0.3))
                guard let self, self.muting, self.muteEpoch == epoch else { return }
                self.muteCurrentDefault()
            }
        }
    }

    // Mute the current default output if we have not already. Re-asserts on a device we are tracking too,
    // in case the route switch cleared the flag we set.
    private func muteCurrentDefault() {
        guard let device = defaultOutputDeviceID() else { return }
        if let existing = mutedEntries.first(where: { $0.device == device }) {
            _ = setOutputMute(1, existing.device)
            return
        }
        guard let current = outputMuteState(device) else { return }
        let uid = deviceUID(device)
        // Record the durable crash-recovery marker for the first (primary) device only — the common case is
        // a single device; the in-process restore below covers the rest.
        if mutedEntries.isEmpty, let uid {
            restorer?.recordOutputMute(deviceUID: uid, previousMute: current)
        }
        mutedEntries.append(MutedEntry(uid: uid, device: device, previous: current))
        _ = setOutputMute(1, device)
    }

    private func restoreOutput() {
        muting = false
        muteFollowTask?.cancel()
        muteFollowTask = nil
        guard !mutedEntries.isEmpty else { return }
        let entries = mutedEntries
        mutedEntries = []
        for entry in entries {
            _ = setOutputMute(entry.previous, entry.device)
        }
        // Clear the marker only AFTER the in-process restore: a crash in between just makes launch reconcile
        // re-apply the same (already-correct) value — idempotent.
        restorer?.clearOutputMute()
        scheduleRestoreReapply(entries: entries)
    }

    // A Bluetooth output switching HFP->A2DP as the mic closes is mid-route-change exactly when we restore,
    // so the unmute write can be dropped and the headset is stranded muted. Re-assert each restored value
    // by UID after the route settles. Guarded on muteEpoch + !muting so a fresh dictation's mute is never
    // clobbered: a new mute bumps the epoch and sets muting, and we bail.
    private func scheduleRestoreReapply(entries: [MutedEntry]) {
        let epoch = muteEpoch
        Task { @MainActor [weak self] in
            for delay in self?.reapplyDelays ?? [] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.muteEpoch == epoch, !self.muting else { return }
                for entry in entries {
                    let device = entry.uid.flatMap { self.resolveOutputDevice($0) } ?? entry.device
                    _ = self.setOutputMute(entry.previous, device)
                }
            }
        }
    }
}
