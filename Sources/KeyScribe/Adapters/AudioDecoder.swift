import AVFoundation
import Foundation

// Single audio-decode path shared by engines needing raw PCM at a specific rate (Qwen3 @24k, Moonshine
// @16k). Reads a wav into mono Float32, resampling through AVAudioConverter only when the source rate/layout
// differs (the common 16 kHz-mono clip takes the fast path). Engines whose SDK consumes a file path
// (Whisper) or own their converter (Parakeet) don't use this. Chunked decode bounds peak memory to one
// chunk plus the growing result.
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
        // AVAudioFile.read(into:) throws (a bare `nilError`) at EOF instead of a zero-length read, so a throw
        // after ≥1 successful read is normal EOF — break rather than fail the decode. A throw on the very
        // first read is a real error and propagates. (ChunkReader.feed swallows the same throw.)
        var read = 0
        while true {
            do { try file.read(into: chunk) } catch {
                if read == 0 { throw error }
                break
            }
            if chunk.frameLength == 0 { break }
            read += 1
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

// AVAudioConverter's input block is @Sendable under strict concurrency. Box the file + reusable chunk in an
// @unchecked Sendable holder — convert(...) consumes each supplied chunk synchronously before requesting the
// next, so reusing one buffer is safe.
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
