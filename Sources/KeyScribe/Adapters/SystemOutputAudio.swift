import CoreAudio
import Foundation

// The system default OUTPUT device and the ducking control KeyScribe uses to silence other audio while
// dictating. Ducking is the private CoreAudio `AudioDeviceDuck` (the same call FaceTime/Siri use): it is
// process-scoped, so the OS releases it the instant our process exits — a crash/SIGKILL/force-quit
// mid-dictation cannot strand the device, unlike the output mute flag it replaces. Weak-linked via dlsym
// and feature-detected: if the symbol is ever absent on a future macOS, duck() reports failure and the
// caller no-ops rather than crashing. All calls are fast, non-blocking HAL operations — safe from any thread.
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

    // Ramp other audio on the device to `level` (0 = silence, 1 = full volume) over a short fade. Returns
    // false if the OS does not expose AudioDeviceDuck — the caller treats that as "ducking unavailable".
    @discardableResult
    static func duck(_ level: Float32, on device: AudioDeviceID) -> Bool {
        guard let duck = audioDeviceDuck else { return false }
        return duck(device, level, nil, rampSeconds) == noErr
    }

    private static let rampSeconds: Float32 = 0.3

    // Legacy-only: clear the device mute flag. KeyScribe no longer mutes (it ducks), but an OLDER build
    // could have crashed while output was muted and left a recovery marker; launch reconcile uses this once
    // to undo such a pre-duck strand. Safe to remove once no pre-duck markers remain in the wild.
    @discardableResult
    static func setMute(_ value: UInt32, on device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var v = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &v) == noErr
    }

    private typealias AudioDeviceDuckFn =
        @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

    private static let audioDeviceDuck: AudioDeviceDuckFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "AudioDeviceDuck") else { return nil }
        return unsafeBitCast(sym, to: AudioDeviceDuckFn.self)
    }()
}
