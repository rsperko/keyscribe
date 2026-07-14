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
    // Every device ducked this dictation. A Bluetooth headset shifts the audible output between its A2DP
    // and HFP instances as the mic opens, so each one seen as default is ducked, then all are unducked
    // together. No prior value is captured: restore always ramps to full volume, so a crash before restore
    // can't strand a device.
    private var duckedDevices: Set<AudioDeviceID> = []
    private var ducking = false
    private var duckFollowTask: Task<Void, Never>?
    private var generation = 0
    // Bumped on each duck start; the follow loop and restore re-apply guard on it so a later dictation's
    // duck is never clobbered by a stale task.
    private var duckEpoch = 0
    // Set when a dictation arms ducking; applied only once capture is live (activateDuck) so on a Bluetooth
    // output it lands after the A2DP->HFP route switch settles. Cleared on apply or cancel.
    private var pendingDuckGeneration: Int?
    private let defaultOutputDeviceID: () -> AudioDeviceID?
    private let setDuck: (Float32, AudioDeviceID) -> Bool
    private let reapplyDelays: [Double]
    private let duckFollowInterval: Double
    // Test seam: forces `begin`'s reported cue length without the bundled asset, so the cue-overlap hold
    // path is exercisable under `swift test`. nil in production → real cue duration.
    private let startCueDurationOverride: TimeInterval?

    init(
        defaultOutputDeviceID: @escaping () -> AudioDeviceID? = SystemOutputAudio.defaultOutputDeviceID,
        setDuck: @escaping (Float32, AudioDeviceID) -> Bool = SystemOutputAudio.duck,
        // Span a Bluetooth route-switch settle: an early re-assert may land mid-switch, so keep re-asserting
        // out to ~2.5s when a later one can land cleanly on the settled (A2DP) device.
        reapplyDelays: [Double] = [0.4, 1.0, 2.5],
        // While recording, re-check the default output this often and duck it if the route moved to a
        // not-yet-ducked device (the Bluetooth A2DP<->HFP shift).
        duckFollowInterval: Double = 0.3,
        startCueDurationOverride: TimeInterval? = nil
    ) {
        self.defaultOutputDeviceID = defaultOutputDeviceID
        self.setDuck = setDuck
        self.reapplyDelays = reapplyDelays
        self.duckFollowInterval = duckFollowInterval
        self.startCueDurationOverride = startCueDurationOverride
    }
    // NSSound(named:) re-resolves on each call; cache one instance per cue so begin/end don't re-resolve
    // every dictation.
    private var soundCache: [String: NSSound] = [:]

    private func sound(named name: String) -> NSSound? {
        if let cached = soundCache[name] { return cached }
        let sound = NSSound(named: name)
        soundCache[name] = sound
        return sound
    }

    // First-party ~110ms cue in Resources/ (NOT a system sound): short so gating capture on it costs
    // little, and original so the GPLv3 bundle ships no redistributed Apple audio. Loaded eagerly
    // (byReference: false) and cached so play() never touches disk. Absent (unbundled dev run) → no cue.
    private func startCueSound() -> NSSound? {
        if let cached = soundCache[Self.startCueKey] { return cached }
        guard let url = Bundle.main.url(forResource: "start-cue", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        soundCache[Self.startCueKey] = sound
        return sound
    }

    private static let startCueKey = "__start-cue"

    // Returns how long the caller should defer capture so the start cue stays out of the recording: the
    // cue's duration when one plays, else 0 (sounds off / cue absent). The duck follows the same deferral.
    @discardableResult
    func begin(_ config: Settings.DuringDictation) -> TimeInterval {
        generation &+= 1
        if config.keepDisplayAwake { acquireDisplayAssertion() }
        // Arm ducking now, apply only once capture is live (activateDuck). It must wait because the start
        // cue routes through the same output (ducking first swallows it) and a Bluetooth output is mid
        // A2DP->HFP switch until capture comes up. Cancelled-before-capture bumps generation → duck dropped.
        pendingDuckGeneration = config.muteSystemAudio ? generation : nil
        guard config.sounds else { return 0 }
        if let startCueDurationOverride { return startCueDurationOverride }
        let startCue = startCueSound()
        startCue?.play()
        return startCue?.duration ?? 0
    }

    // Apply the armed duck. Called when capture goes live (route settled) — never from begin.
    func activateDuck() {
        guard let armed = pendingDuckGeneration, armed == generation else { return }
        pendingDuckGeneration = nil
        startDucking()
    }

    // Restore the ducked output as soon as capture is done, not waiting for transcription + LLM rewrite.
    // The generation bump drops any still-pending deferred duck (begin's cue-gated Task) so a
    // sub-cue-length press can't re-duck after this. Idempotent, so a later end(...) is a no-op.
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
        // the mic opens, so poll the default and duck whatever it becomes for the recording's life.
        let epoch = duckEpoch
        duckFollowTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(self?.duckFollowInterval ?? 0.3))
                guard let self, self.ducking, self.duckEpoch == epoch else { return }
                self.duckCurrentDefault()
            }
        }
    }

    // Duck the current default output, re-asserting on an already-tracked device in case the route switch
    // cleared it. Track only when the duck took — if the private API is absent (future macOS) every call
    // fails, so the set stays empty and restore is a clean no-op instead of unducking a duck that never was.
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
    // so the unduck write can be dropped and the headset left quiet. Re-assert full volume on each ducked
    // device plus the current default (the route may have moved). Guarded on duckEpoch + !ducking so a fresh
    // dictation's duck is never clobbered. A missed re-assert isn't a strand — the duck releases on exit.
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
