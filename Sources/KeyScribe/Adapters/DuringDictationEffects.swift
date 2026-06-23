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
    private var generation = 0

    func begin(_ config: Settings.DuringDictation) {
        generation &+= 1
        if config.keepDisplayAwake { acquireDisplayAssertion() }
        let startCue = config.sounds ? NSSound(named: "Tink") : nil
        startCue?.play()
        guard config.muteSystemAudio else { return }
        // Mute the output device AFTER the start cue plays — muting it first swallows the cue, since
        // the cue routes through that same device. Defer past the cue's length; the generation guard
        // drops the mute if the dictation already ended (a sub-cue-length press must never leave the
        // output muted for good).
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

    func end(_ config: Settings.DuringDictation, cue: EndCue = .success) {
        generation &+= 1
        releaseDisplayAssertion()
        restoreOutput()
        if config.sounds { NSSound(named: cue.soundName)?.play() }
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
        var muted: UInt32 = 1
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &muted)
    }

    private func restoreOutput() {
        guard let previousMute, let device = defaultOutputDevice() else { return }
        var addr = muteAddress()
        var value = previousMute
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
        self.previousMute = nil
    }
}
