import AVFoundation
import CoreAudio
import Foundation

// Delivered on the CoreAudio IO thread: the freshly rendered buffer (client format = device-native
// rate/channels, Float32 non-interleaved) and its host time (nil when the timestamp's host time is not
// valid — the drain gate has a buffer-count fallback for that). File-scoped (not nested) so the C render
// callback below can resolve it from the opaque refcon.
private final class HALRenderContext {
    var unit: AudioUnit?
    var format: AVAudioFormat?
    var scratch: AVAudioPCMBuffer?
    let handler: (AVAudioPCMBuffer, UInt64?) -> Void
    init(handler: @escaping (AVAudioPCMBuffer, UInt64?) -> Void) { self.handler = handler }
}

// Raw AUHAL (`kAudioUnitSubType_HALOutput`) input unit for device-pinned capture with NO global side
// effects. It binds the chosen device on the unit's `CurrentDevice` and matches the client stream format
// to that device's OWN native format — the fix for the -10868 (`kAudioUnitErr_FormatNotSupported`) that
// `AVAudioEngine.inputNode` cannot cleanly do (inputNode caches a stale format after a device swap and
// exposes no supported "set client format after CurrentDevice" seam). It NEVER writes
// `kAudioHardwarePropertyDefaultInputDevice`, so selecting a non-default mic (even while Bluetooth holds
// the system default) does not hijack every other app's microphone — the antipattern we deleted.
//
// Threading: every control call (`configure`/`start`/`stop`/`dispose`) can BLOCK on a transitioning
// device (classically a Bluetooth headset forced A2DP→HFP the instant capture opens), so the OWNER must
// invoke them off the main thread on a serial queue under a watchdog (see `AudioCapture`). This type is
// therefore control-queue-confined and NOT internally synchronized. The render callback runs on
// CoreAudio's realtime IO thread — a different thread from the control queue — and only touches the
// caller-provided handler + a reusable scratch buffer (the delivery is serial, like an AVAudioEngine tap).
final class HALInputUnit {
    struct UnitError: Error { let status: OSStatus; let stage: String }

    private var unit: AudioUnit?
    private let context: HALRenderContext
    // The device-native format the unit delivers (Float32 non-interleaved at the device's own rate/channel
    // count). The owner converts this down to the 16 kHz mono WAV target in software — the AUHAL is never
    // asked for a rate/channel count the hardware cannot produce, which is exactly how -10868 is avoided.
    private(set) var clientFormat: AVAudioFormat?

    init(handler: @escaping (AVAudioPCMBuffer, UInt64?) -> Void) {
        self.context = HALRenderContext(handler: handler)
    }

    var isConfigured: Bool { unit != nil }

    // Create + configure + INITIALIZE the unit bound to `deviceID`, ending realized-but-not-capturing
    // (no IOProc running, so the mic indicator does not light — that is `start()`). Strict ordering:
    // enable input / disable output → set CurrentDevice → read the device's NATIVE format → set the client
    // format matched to it → install the input callback → initialize. Throws (leaving nothing realized) on
    // any step, so the owner can map the failure to the right user-facing error.
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

        // On any failure past this point the half-built unit must be disposed, or it leaks an initialized
        // I/O proc and holds the device (a Bluetooth headset would stay in HFP).
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

            // Read the device's native input format AFTER binding it, so the client format below matches
            // the actual hardware (a Bluetooth HFP device sits at 1 ch / ~16 kHz; a USB mic at 48 kHz).
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

            // We render into our own AVAudioPCMBuffer, so the unit must not allocate its own input buffer.
            var shouldAllocate: UInt32 = 0
            _ = AudioUnitSetProperty(
                au, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1,
                &shouldAllocate, UInt32(MemoryLayout<UInt32>.size))

            context.unit = au
            context.format = client
            context.scratch = nil
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
            context.format = nil
            throw error
        }
    }

    func start() throws {
        guard let unit else { throw UnitError(status: -1, stage: "start.notConfigured") }
        try check(AudioOutputUnitStart(unit), "start")
    }

    // Stop the IOProc but keep the unit realized (fast to re-`start()`). The owner uses this for a healthy
    // teardown of a non-Bluetooth device so the next dictation reuses the resident unit.
    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
    }

    // Stop → uninitialize → dispose, releasing the device entirely (frees a Bluetooth headset from HFP).
    // Idempotent. The input callback cannot fire after `AudioOutputUnitStop` returns, so tearing the
    // context down here does not race a live render.
    func dispose() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        clientFormat = nil
        context.unit = nil
        context.format = nil
        context.scratch = nil
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw UnitError(status: status, stage: stage) }
    }
}

// C render callback: pull the just-captured frames into a reusable AVAudioPCMBuffer (no per-callback heap
// churn; delivery is serial so reuse is safe) and hand them to the owner's handler. Returns the render
// status so CoreAudio sees a failed pull rather than silently corrupt audio.
private let halInputRenderCallback: AURenderCallback = {
    refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let context = Unmanaged<HALRenderContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = context.unit, let format = context.format else { return noErr }
    if context.scratch == nil || context.scratch!.frameCapacity < inNumberFrames {
        context.scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames)
    }
    guard let buffer = context.scratch else { return noErr }
    buffer.frameLength = inNumberFrames
    let status = AudioUnitRender(
        unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, buffer.mutableAudioBufferList)
    guard status == noErr else { return status }
    let timestamp = inTimeStamp.pointee
    let hostTime: UInt64? = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : nil
    context.handler(buffer, hostTime)
    return noErr
}
