import AVFoundation
import Foundation

// Single audio-decode path shared by the engines that need raw PCM at a specific rate (Qwen3 @24k,
// Moonshine @16k). Reads a wav into mono Float32, resampling through AVAudioConverter only when the
// source rate/layout differs (the common 16 kHz-mono dictation clip takes the fast path). Engines
// whose SDK consumes a file path (Whisper) or owns its own converter (Parakeet/FluidAudio) don't use
// this. Decode runs in fixed-size frame chunks so peak memory is bounded by one chunk plus the
// growing result, not two whole-clip PCM buffers held at once.
enum AudioDecoder {
    private static let chunkFrames: AVAudioFrameCount = 16384

    static func pcmMono(_ url: URL, sampleRate: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat

        if Int(source.sampleRate) == sampleRate && source.channelCount == 1 {
            return try readChunks(file, format: source)
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target)
        else { throw EngineError.audioDecodeFailed }

        let reader = ChunkReader(file: file, format: source, chunkFrames: chunkFrames)
        let ratio = Double(sampleRate) / source.sampleRate
        let outCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024
        let outChunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity)!

        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * ratio) + Int(outCapacity))
        while true {
            outChunk.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outChunk, error: &convError, withInputFrom: reader.feed)
            if convError != nil { throw EngineError.audioDecodeFailed }
            append(outChunk, to: &out)
            if status == .haveData { continue }
            break
        }
        return out
    }

    private static func readChunks(_ file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
        var out: [Float] = []
        out.reserveCapacity(Int(file.length))
        while true {
            try file.read(into: chunk)
            if chunk.frameLength == 0 { break }
            append(chunk, to: &out)
        }
        return out
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to out: inout [Float]) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ptr = buffer.floatChannelData?[0] else { return }
        out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
    }
}

// AVAudioConverter's input block is @Sendable under strict concurrency. Box the file + reusable input
// chunk in an @unchecked Sendable holder — convert(to:error:withInputFrom:) consumes each supplied
// chunk synchronously on one thread before requesting the next, so reusing one buffer is safe.
private final class ChunkReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(file: AVAudioFile, format: AVAudioFormat, chunkFrames: AVAudioFrameCount) {
        self.file = file
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
    }

    func feed(
        _ count: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        do {
            try file.read(into: buffer)
        } catch {
            status.pointee = .endOfStream
            return nil
        }
        if buffer.frameLength == 0 {
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
