import Accelerate
import AVFoundation
import Foundation

protocol AudioCapturing: AnyObject {
    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL
    func stop() -> URL?
}

enum AudioCaptureError: Error { case formatUnavailable }

private final class FeedOnce: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

final class AudioCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var levelHandler: (@Sendable (Float) -> Void)?
    // Resamples the mic's native format down to the engine's target rate/mono so the WAV is written at
    // the rate STT wants — no oversized capture file, no decode-time resample. Nil when the mic already
    // delivers the target format. Reused across callbacks (one buffer; the tap fires serially).
    private var converter: AVAudioConverter?
    private var outBuffer: AVAudioPCMBuffer?

    func start(sampleRate: Int, levelHandler: @escaping @Sendable (Float) -> Void) throws -> URL {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false) else { throw AudioCaptureError.formatUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-capture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: recordFormat.settings)

        var converter: AVAudioConverter?
        var outBuffer: AVAudioPCMBuffer?
        if inputFormat.sampleRate != recordFormat.sampleRate
            || inputFormat.channelCount != recordFormat.channelCount {
            guard let c = AVAudioConverter(from: inputFormat, to: recordFormat) else {
                throw AudioCaptureError.formatUnavailable
            }
            let ratio = recordFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(4096) * ratio) + 1024
            converter = c
            outBuffer = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: capacity)
        }

        lock.lock()
        self.file = file
        self.currentURL = url
        self.levelHandler = levelHandler
        self.converter = converter
        self.outBuffer = outBuffer
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            if let url = stop() { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return url
    }

    func stop() -> URL? {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        let url = currentURL
        file = nil
        currentURL = nil
        levelHandler = nil
        converter = nil
        outBuffer = nil
        return url
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = self.file
        let handler = self.levelHandler
        let converter = self.converter
        let outBuffer = self.outBuffer
        lock.unlock()

        guard let converter, let outBuffer else {
            try? file?.write(from: buffer)
            emitLevel(buffer, to: handler)
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
