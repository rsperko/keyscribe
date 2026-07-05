import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// File-scoped so the C render callback can resolve it from the opaque refcon.
private final class HALRenderContext {
    var unit: AudioUnit?
    var scratch: AVAudioPCMBuffer?
    // Buffers dropped because the device grew its IO period past the preallocated scratch mid-capture: the
    // realtime callback must not reallocate, so it drops (counted) instead. Read off-RT for diagnostics.
    let oversizeDrops = Atomic<UInt64>(0)
    let handler: (AVAudioPCMBuffer, UInt64?) -> Void
    init(handler: @escaping (AVAudioPCMBuffer, UInt64?) -> Void) { self.handler = handler }
}

// Raw AUHAL input unit for device-pinned capture without global default-device side effects.
//
// Control calls can block on transitioning devices, so the owner confines them to an off-main serial
// queue under a watchdog. The render callback runs on CoreAudio's realtime thread.
final class HALInputUnit {
    struct UnitError: Error { let status: OSStatus; let stage: String }

    private var unit: AudioUnit?
    private let context: HALRenderContext
    // Device-native Float32 non-interleaved format; conversion happens in the owner.
    private(set) var clientFormat: AVAudioFormat?

    // Realtime callbacks can't allocate, so scratch is preallocated to at least this ceiling (the ring's slot
    // ceiling); a device that later grows its IO period past it drops the oversize buffer rather than realloc.
    static let scratchFrameCeiling: AVAudioFrameCount = 8192

    // Buffers dropped on the realtime thread because the device's IO period grew past the preallocated scratch.
    var oversizeDropCount: Int { Int(context.oversizeDrops.load(ordering: .relaxed)) }

    init(handler: @escaping (AVAudioPCMBuffer, UInt64?) -> Void) {
        self.context = HALRenderContext(handler: handler)
    }

    var isConfigured: Bool { unit != nil }

    // Configure and initialize the unit without starting the IOProc.
    func configure(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw UnitError(status: -1, stage: "findComponent")
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(component, &au), "instanceNew")
        guard let au else { throw UnitError(status: -1, stage: "instanceNew.nil") }

        // Dispose the half-built unit on failure so it cannot keep holding the device.
        do {
            var enableInput: UInt32 = 1
            try check(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enableInput, UInt32(MemoryLayout<UInt32>.size)), "enableInput")
            var disableOutput: UInt32 = 0
            try check(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disableOutput, UInt32(MemoryLayout<UInt32>.size)), "disableOutput")

            var device = deviceID
            try check(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "setCurrentDevice")

            // Read the native format after binding so the client format matches the actual hardware.
            var native = AudioStreamBasicDescription()
            var nativeSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(
                au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                &native, &nativeSize), "getNativeFormat")
            guard let client = AudioCapture.clientStreamFormat(
                nativeSampleRate: native.mSampleRate, nativeChannels: native.mChannelsPerFrame) else {
                throw UnitError(status: -1, stage: "clientFormat")
            }
            var clientASBD = client.streamDescription.pointee
            try check(AudioUnitSetProperty(
                au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &clientASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "setClientFormat")

            // We render into our own scratch buffer.
            var shouldAllocate: UInt32 = 0
            _ = AudioUnitSetProperty(
                au, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1,
                &shouldAllocate, UInt32(MemoryLayout<UInt32>.size))

            context.unit = au
            context.scratch = AVAudioPCMBuffer(
                pcmFormat: client,
                frameCapacity: Self.scratchFrameCapacity(deviceBufferFrameSize: Self.deviceBufferFrameSize(deviceID)))
            var callback = AURenderCallbackStruct(
                inputProc: halInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try check(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "setInputCallback")

            try check(AudioUnitInitialize(au), "initialize")
            unit = au
            clientFormat = client
        } catch {
            AudioComponentInstanceDispose(au)
            context.unit = nil
            throw error
        }
    }

    func start() throws {
        guard let unit else { throw UnitError(status: -1, stage: "start.notConfigured") }
        try check(AudioOutputUnitStart(unit), "start")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
    }

    // Stop, uninitialize, and dispose, releasing the device entirely.
    func dispose() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        clientFormat = nil
        context.unit = nil
        context.scratch = nil
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw UnitError(status: status, stage: stage) }
    }

    // Size scratch to at least the ceiling so an in-spec device (period ≤ ceiling) never needs the realtime
    // thread to grow it; a larger reported period is honored up front so only a mid-capture growth drops.
    static func scratchFrameCapacity(deviceBufferFrameSize: UInt32) -> AVAudioFrameCount {
        max(AVAudioFrameCount(deviceBufferFrameSize), scratchFrameCeiling)
    }

    private static func deviceBufferFrameSize(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }
}

// Pull the just-captured frames into a reusable buffer and hand them to the owner's handler.
private let halInputRenderCallback: AURenderCallback = {
    refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let context = Unmanaged<HALRenderContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = context.unit else { return noErr }
    // No allocation on the realtime thread: if the device grew its IO period past the preallocated scratch,
    // drop this buffer (counted) rather than reallocate. The ring drops the same oversize the same way.
    guard let buffer = context.scratch, buffer.frameCapacity >= inNumberFrames else {
        context.oversizeDrops.add(1, ordering: .relaxed)
        return noErr
    }
    buffer.frameLength = inNumberFrames
    let status = AudioUnitRender(
        unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, buffer.mutableAudioBufferList)
    guard status == noErr else { return status }
    let timestamp = inTimeStamp.pointee
    let hostTime: UInt64? = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : nil
    context.handler(buffer, hostTime)
    return noErr
}
