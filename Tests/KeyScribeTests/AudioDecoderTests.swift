import AVFoundation
import Foundation
import Testing
@testable import KeyScribeApp

struct AudioDecoderTests {
    @Test func inMemoryResampleMatchesDecodingTheSameSamplesFromAWav() throws {
        let rate = 24_000
        let samples = (0..<(rate * 3)).map { Float(sin(Double($0) * 2 * .pi * 440 / Double(rate))) * 0.5 }
        let wav = try Self.writeWAV(samples, rate: rate)
        defer { try? FileManager.default.removeItem(at: wav) }

        let fromFile = try AudioDecoder.pcmMono(wav, sampleRate: 16_000)
        let inMemory = try AudioDecoder.resampleMono(samples, from: rate, to: 16_000)

        #expect(inMemory == fromFile)
        #expect(abs(inMemory.count - 48_000) <= 256)
    }

    @Test func resamplingToTheSameRateReturnsTheInputUnchanged() throws {
        let samples: [Float] = [0.1, -0.2, 0.3]
        #expect(try AudioDecoder.resampleMono(samples, from: 16_000, to: 16_000) == samples)
    }

    @Test func resamplingNothingReturnsNothing() throws {
        #expect(try AudioDecoder.resampleMono([], from: 24_000, to: 16_000).isEmpty)
    }

    private static func writeWAV(_ samples: [Float], rate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-decoder-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        return url
    }
}
