import CoreAudio
import Foundation

// Ducking uses CoreAudio's process-scoped `AudioDeviceDuck` (OS releases it on exit); the symbol is
// weak-linked via dlsym, so duck() reports failure when absent.
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

    static func defaultOutputDescription() -> String? {
        guard let device = defaultOutputDeviceID() else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?
        let named = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0)
        } == noErr
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        let rated = AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr
        let label = named ? (name?.takeRetainedValue() as String?) ?? "Unknown device" : "Unknown device"
        return rated ? "\(label), \(Int(rate)) Hz" : label
    }

    // level: 0 = silence, 1 = full volume. Returns false when AudioDeviceDuck is unavailable.
    @discardableResult
    static func duck(_ level: Float32, on device: AudioDeviceID) -> Bool {
        guard let duck = audioDeviceDuck else { return false }
        return duck(device, level, nil, rampSeconds) == noErr
    }

    private static let rampSeconds: Float32 = 0.3

    // Legacy-only recovery for mute markers written by earlier builds.
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
