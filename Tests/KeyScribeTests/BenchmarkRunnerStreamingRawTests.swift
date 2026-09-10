import AVFoundation
import Foundation
import Testing
@testable import KeyScribeApp
import KeyScribeKit

struct BenchmarkRunnerStreamingRawTests {
    private struct BatchFailed: Error {}

    private final class ShortClipEngine: SpeechEngine, @unchecked Sendable {
        let id = "short-clip"
        let displayName = "Short Clip"
        let supportsRecognitionBias = false
        let supportsStreaming = true
        let batchFails: Bool
        init(batchFails: Bool) { self.batchFails = batchFails }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            if batchFails { throw BatchFailed() }
            return "batch text"
        }
        func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
            throw BatchFailed()
        }
        func evict() async {}
    }

    private func halfSecondWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-streaming-raw-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func aClipThatFallsBackToBatchReportsTheBatchTranscript() async throws {
        let wav = try halfSecondWAV()
        defer { try? FileManager.default.removeItem(at: wav) }

        let result = await BenchmarkRunner.rawStreamingTranscript(engine: ShortClipEngine(batchFails: false), wav: wav)

        #expect(result.text == "batch text")
        #expect(result.outcome == .transcribed)
    }

    @Test func aClipWhoseFallbackBatchFailsIsAFailure() async throws {
        let wav = try halfSecondWAV()
        defer { try? FileManager.default.removeItem(at: wav) }

        let result = await BenchmarkRunner.rawStreamingTranscript(engine: ShortClipEngine(batchFails: true), wav: wav)

        #expect(result.text == "<error>")
        guard case .failed = result.outcome else {
            Issue.record("expected a failed outcome, got \(result.outcome)")
            return
        }
    }
}
