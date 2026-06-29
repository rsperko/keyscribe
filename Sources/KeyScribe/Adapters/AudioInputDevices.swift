import CoreAudio
import Foundation

// CoreAudio input-device enumeration and resolution, shared by the Settings picker (list/label) and
// AudioCapture (resolve the preferred UID to a live device, classify its transport). All reads are
// fast, non-blocking HAL property queries — never the AVAudioEngine control path — so they are safe to
// call from the main thread (picker) or the audio control queue (capture).
enum AudioInputDevices {
    struct Device: Equatable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    // Every device that currently exposes at least one input stream, in HAL order. A device's UID is
    // stable across reconnect/reboot; its AudioDeviceID is not, so resolution always goes through the UID.
    static func available() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id), let uid = uid(of: id) else { return nil }
            return Device(id: id, uid: uid, name: name(of: id) ?? uid)
        }
    }

    // Resolve a saved preferred UID to a currently-connected input device, or nil if it is absent.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        available().first { $0.uid == uid }?.id
    }

    // Resolve a UID to ANY currently-connected device (input or output), or nil if absent. Used by the
    // crash-recovery reconcile to restore an output device's mute by UID — output devices have no input
    // streams, so `deviceID(forUID:)` (input-only) would not find them.
    static func deviceID(forAnyUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { Self.uid(of: $0) == uid }
    }

    // The device's stable UID (input or output). Exposed so callers can persist a device identity across
    // launches/reboots; AudioDeviceID is transient and must never be stored.
    static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    // The system default *input* device, or nil if it has no input stream (CoreAudio can name an
    // output-only default during route churn — device 106 in the crash log).
    static func systemDefaultInputID() -> AudioDeviceID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0, hasInputStreams(deviceID) else { return nil }
        return deviceID
    }

    static func systemDefaultInput() -> Device? {
        guard let id = systemDefaultInputID(), let uid = uid(of: id) else { return nil }
        return Device(id: id, uid: uid, name: name(of: id) ?? uid)
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        guard let transport = transportType(of: id) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // Set the system default *input* device. Returns true on success. This is a GLOBAL change that affects
    // every app on the machine, so a caller must save the prior default and restore it (see AudioCapture's
    // temporary-default swap) — leaving it changed would hijack every other app's microphone.
    @discardableResult
    static func setSystemDefaultInput(_ id: AudioDeviceID) -> Bool {
        var deviceID = id
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
    }

    // MARK: - Property reads

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32? {
        var addr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
