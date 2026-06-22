import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import KeyScribeKit

@MainActor
final class DuringDictationEffects {
    private var displayAssertion: IOPMAssertionID = 0
    private var hadDisplayAssertion = false
    private var previousMute: UInt32?

    func begin(_ config: Settings.DuringDictation) {
        if config.keepDisplayAwake { acquireDisplayAssertion() }
        if config.muteSystemAudio { muteOutput() }
        if config.sounds { NSSound(named: "Tink")?.play() }
    }

    func end(_ config: Settings.DuringDictation) {
        releaseDisplayAssertion()
        restoreOutput()
        if config.sounds { NSSound(named: "Pop")?.play() }
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
