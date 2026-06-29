import CoreAudio
import Foundation

// The system default OUTPUT device and its mute flag. Shared by DuringDictationEffects (mute while
// dictating) and SystemAudioStateRestorer (crash-recovery reconcile) so the mute property access lives in
// exactly one place. All calls are fast, non-blocking HAL property queries — safe from any thread.
enum SystemOutputAudio {
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    // The device's mute flag (0/1), or nil if the device exposes no controllable mute property.
    static func muteState(of device: AudioDeviceID) -> UInt32? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &current) == noErr else { return nil }
        return current
    }

    @discardableResult
    static func setMute(_ value: UInt32, on device: AudioDeviceID) -> Bool {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var v = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &v) == noErr
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }
}
