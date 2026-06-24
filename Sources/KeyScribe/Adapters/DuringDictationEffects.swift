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
    private var previousMute: UInt32?
    private var mutedDevice: AudioDeviceID?
    private var generation = 0
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
        let startCue = config.sounds ? startCueSound() : nil
        startCue?.play()
        if config.muteSystemAudio {
            // Mute the output device AFTER the start cue plays — muting it first swallows the cue, since
            // the cue routes through that same device. With the cue OFF the mute is instant; with the cue
            // ON we defer past its length. The generation guard drops the mute if the dictation already
            // ended (a sub-cue-length press must never leave the output muted).
            if let startCue {
                let gen = generation
                let delay = startCue.duration
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.generation == gen else { return }
                    self.muteOutput()
                }
            } else {
                muteOutput()
            }
        }
        return startCue?.duration ?? 0
    }

    func end(_ config: Settings.DuringDictation, cue: EndCue = .success) {
        generation &+= 1
        releaseDisplayAssertion()
        restoreOutput()
        if config.sounds { sound(named: cue.soundName)?.play() }
    }

    private func acquireDisplayAssertion() {
        guard !hadDisplayAssertion else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "KeyScribe dictating" as CFString,
            &displayAssertion)
        hadDisplayAssertion = (ok == kIOReturnSuccess)
    }

    private func releaseDisplayAssertion() {
        guard hadDisplayAssertion else { return }
        IOPMAssertionRelease(displayAssertion)
        hadDisplayAssertion = false
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func muteOutput() {
        guard let device = defaultOutputDevice() else { return }
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return }
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &current) == noErr else { return }
        previousMute = current
        mutedDevice = device
        var muted: UInt32 = 1
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &muted)
    }

    private func restoreOutput() {
        // Restore the exact device we muted, not the current default. If the output device changed
        // mid-dictation (e.g. headphones unplugged), re-resolving the default would leave the device we
        // muted stuck muted forever and wrongly write our saved state onto the new default device.
        guard let previousMute, let device = mutedDevice else { return }
        var addr = muteAddress()
        var value = previousMute
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
        self.previousMute = nil
        self.mutedDevice = nil
    }
}
