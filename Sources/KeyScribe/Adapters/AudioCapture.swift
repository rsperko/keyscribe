import Accelerate
import AVFoundation
import Foundation

protocol AudioCapturing: AnyObject {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL
    func stop() -> URL?
    func prewarm()
}

extension AudioCapturing {
    func prewarm() {}
}

enum AudioCaptureError: Error { case formatUnavailable }

private final class FeedOnce: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

final class AudioCapture: AudioCapturing, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var recordFormat: AVAudioFormat?
    // Resamples the mic's native format down to the engine's target rate/mono so the WAV is written at
    // the rate STT wants — no oversized capture file, no decode-time resample. Built lazily from the
    // format the tap actually delivers (not a pre-queried one, which can be stale) and rebuilt if the
    // hardware format changes mid-stream. Reused across callbacks (the tap fires serially).
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var outBuffer: AVAudioPCMBuffer?

    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL {
        guard let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false) else { throw AudioCaptureError.formatUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        lock.lock()
        self.file = file
        self.currentURL = url
        self.levelHandler = levelHandler
        self.recordFormat = recordFormat
        self.converter = nil
        self.converterInputFormat = nil
        self.outBuffer = nil
        lock.unlock()

        do {
            try arm()
        } catch {
            // The engine caches its input-device binding and never re-resolves it, so if that device
            // disconnected while idle (no ConfigurationChange fires while stopped) start() throws. Rebuild
            // the engine once to bind the current default input and retry — the costly input-unit
            // realization is paid only on a device change, not on every dictation.
            engine = AVAudioEngine()
            do {
                try arm()
            } catch {
                if let url = stop() { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        }
        return url
    }

    // Realize the input HAL unit before the first dictation so capture starts without the one-time
    // ~165 ms unit-realization cost on the hot path. Accessing the input node and its format
    // instantiates the unit and prepare() preallocates its render resources; neither opens a capture
    // stream, so the mic indicator never lights. The caller gates this on a granted mic.
    func prewarm() {
        let input = engine.inputNode
        _ = input.outputFormat(forBus: 0)
        engine.prepare()
    }

    private func arm() throws {
        let input = engine.inputNode
        // format: nil binds the tap to the input node's live hardware format, so there is no passed
        // format for AVFoundation to validate and mismatch against (a 48k-cached / 16k-actual mismatch
        // previously aborted with an uncaught com.apple.coreaudio.avfaudio exception → SIGABRT).
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> URL? {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        let url = currentURL
        file = nil
        currentURL = nil
        levelHandler = nil
        recordFormat = nil
        converter = nil
        converterInputFormat = nil
        outBuffer = nil
        return url
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = self.file
        let handler = self.levelHandler
        guard let recordFormat = self.recordFormat else { lock.unlock(); return }

        let inputFormat = buffer.format
        if inputFormat.sampleRate == recordFormat.sampleRate
            && inputFormat.channelCount == recordFormat.channelCount {
            lock.unlock()
            try? file?.write(from: buffer)
            emitLevel(buffer, to: handler)
            return
        }

        if converter == nil
            || converterInputFormat?.sampleRate != inputFormat.sampleRate
            || converterInputFormat?.channelCount != inputFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: recordFormat)
            converterInputFormat = inputFormat
            outBuffer = nil
        }
        let ratio = recordFormat.sampleRate / inputFormat.sampleRate
        let needed = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        if outBuffer == nil || outBuffer!.frameCapacity < needed {
            outBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: needed)
        }
        let converter = self.converter
        let outBuffer = self.outBuffer
        lock.unlock()

        guard let converter, let outBuffer else {
            return
        }
        outBuffer.frameLength = 0
        var convError: NSError?
        // AVAudioConverter's input block is @Sendable; box the (non-Sendable) live buffer + one-shot
        // flag so it can be fed exactly once. convert() consumes it synchronously before returning.
        let feed = FeedOnce(buffer)
        _ = converter.convert(to: outBuffer, error: &convError) { _, status in
            if feed.consumed { status.pointee = .noDataNow; return nil }
            feed.consumed = true
            status.pointee = .haveData
            return feed.buffer
        }
        guard convError == nil, outBuffer.frameLength > 0 else { return }
        try? file?.write(from: outBuffer)
        emitLevel(outBuffer, to: handler)
    }

    private func emitLevel(_ buffer: AVAudioPCMBuffer, to handler: (@Sendable (Float) -> Void)?) {
        guard let handler else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        handler(Self.perceptualLevel(rms))
    }

    // RMS is linear, so speech-range energy clusters near zero and a linear meter barely moves.
    // Map to dB and rescale a [floor, ceiling] window to 0...1 so normal speech spans most of the bar.
    private static func perceptualLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -52
        let ceiling: Float = -12
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }
}
