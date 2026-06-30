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
    // Every device we have ducked this dictation. A Bluetooth headset shifts the audible output between its
    // A2DP and HFP instances as the mic opens, so the device carrying the audio changes mid-recording; we
    // duck each one we see become the default and unduck them all, never assuming a single device. No prior
    // value is captured: restore always ramps back to full volume (1.0), so there is no muted state we could
    // wrongly restore — and the duck is process-scoped, so a crash before restore can never strand a device.
    private var duckedDevices: Set<AudioDeviceID> = []
    private var ducking = false
    private var duckFollowTask: Task<Void, Never>?
    private var generation = 0
    // Bumped on each duck start. The follow loop and restore re-apply guard on this so a later dictation's
    // duck is never clobbered by a stale task from an earlier one.
    private var duckEpoch = 0
    // Set when a dictation arms ducking; the duck is applied only once capture is live (activateDuck), so
    // on a Bluetooth output it lands after the A2DP->HFP route switch settles. Cleared on apply or cancel.
    private var pendingDuckGeneration: Int?
    private let defaultOutputDeviceID: () -> AudioDeviceID?
    private let setDuck: (Float32, AudioDeviceID) -> Bool
    private let reapplyDelays: [Double]
    private let duckFollowInterval: Double

    init(
        defaultOutputDeviceID: @escaping () -> AudioDeviceID? = SystemOutputAudio.defaultOutputDeviceID,
        setDuck: @escaping (Float32, AudioDeviceID) -> Bool = SystemOutputAudio.duck,
        // Span a Bluetooth route-switch settle window: an early attempt may still land mid-switch, so keep
        // re-asserting out to ~2.5s when a later one can land cleanly on the settled (A2DP) device.
        reapplyDelays: [Double] = [0.4, 1.0, 2.5],
        // While recording, re-check the default output this often and duck it if the route moved to a
        // device we have not ducked yet (the Bluetooth A2DP<->HFP shift).
        duckFollowInterval: Double = 0.3
    ) {
        self.defaultOutputDeviceID = defaultOutputDeviceID
        self.setDuck = setDuck
        self.reapplyDelays = reapplyDelays
        self.duckFollowInterval = duckFollowInterval
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
    // gating). The output duck follows the same deferral so ducking never swallows the cue.
    @discardableResult
    func begin(_ config: Settings.DuringDictation) -> TimeInterval {
        generation &+= 1
        if config.keepDisplayAwake { acquireDisplayAssertion() }
        // Arm ducking now, apply it only once capture is live (activateDuck). Two reasons it must wait:
        // the start cue routes through the same output (ducking first swallows it), and on a Bluetooth
        // output the device is mid A2DP->HFP route switch until capture comes up — ducking then races the
        // switch. Cancelled-before-capture bumps generation, so activateDuck drops the duck.
        pendingDuckGeneration = config.muteSystemAudio ? generation : nil
        let startCue = config.sounds ? startCueSound() : nil
        startCue?.play()
        return startCue?.duration ?? 0
    }

    // Apply the armed duck. Called when capture goes live (the route has settled) — never from begin.
    func activateDuck() {
        guard let armed = pendingDuckGeneration, armed == generation else { return }
        pendingDuckGeneration = nil
        startDucking()
    }

    // Restore the ducked output as soon as capture is done, without waiting for the rest of the
    // dictation (transcription + the cloud LLM rewrite) to finish. There is no reason to keep the
    // output ducked once we have stopped listening. The generation bump drops any still-pending
    // deferred duck (begin's cue-gated Task), so a sub-cue-length press can't re-duck after this.
    // restoreOutput is idempotent, so a later end(...) calling it again is a no-op.
    func restoreAudio() {
        generation &+= 1
        restoreOutput()
    }

    func end(_ config: Settings.DuringDictation, cue: EndCue = .success) {
        generation &+= 1
        pendingDuckGeneration = nil
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

    private func startDucking() {
        guard !ducking else { return }
        ducking = true
        duckEpoch &+= 1
        duckCurrentDefault()
        // Follow the active output: the Bluetooth A2DP<->HFP shift moves the audible device a beat after
        // the mic opens, so poll the default and duck whatever it becomes for the life of the recording.
        let epoch = duckEpoch
        duckFollowTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(self?.duckFollowInterval ?? 0.3))
                guard let self, self.ducking, self.duckEpoch == epoch else { return }
                self.duckCurrentDefault()
            }
        }
    }

    // Duck the current default output. Re-asserts on a device we are already tracking too, in case the
    // route switch cleared the duck we set. Track a device only when the duck actually took — if ducking is
    // unavailable (the private API is absent on a future macOS) every call fails, so the set stays empty and
    // restore is a clean no-op rather than issuing unducks for a duck that never happened.
    private func duckCurrentDefault() {
        guard let device = defaultOutputDeviceID() else { return }
        if setDuck(0, device) { duckedDevices.insert(device) }
    }

    private func restoreOutput() {
        ducking = false
        duckFollowTask?.cancel()
        duckFollowTask = nil
        guard !duckedDevices.isEmpty else { return }
        let devices = duckedDevices
        duckedDevices = []
        for device in devices {
            _ = setDuck(1, device)
        }
        scheduleRestoreReapply(devices: devices)
    }

    // A Bluetooth output switching HFP->A2DP as the mic closes is mid-route-change exactly when we restore,
    // so the unduck write can be dropped and the headset is left quiet. Re-assert full volume on each device
    // we ducked plus whatever is the default now (the route may have moved the audible device). Guarded on
    // duckEpoch + !ducking so a fresh dictation's duck is never clobbered: a new duck bumps the epoch and
    // sets ducking, and we bail. A missed re-assert is not a strand — the duck releases on process exit.
    private func scheduleRestoreReapply(devices: Set<AudioDeviceID>) {
        let epoch = duckEpoch
        Task { @MainActor [weak self] in
            for delay in self?.reapplyDelays ?? [] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.duckEpoch == epoch, !self.ducking else { return }
                for device in devices {
                    _ = self.setDuck(1, device)
                }
                if let current = self.defaultOutputDeviceID() {
                    _ = self.setDuck(1, current)
                }
            }
        }
    }
}
