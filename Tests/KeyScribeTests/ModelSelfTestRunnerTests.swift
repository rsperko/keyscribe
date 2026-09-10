import Foundation
import Testing
@testable import KeyScribeApp
import KeyScribeKit

struct ModelSelfTestRunnerTests {
    private struct Refused: Error {}

    private final class UnavailableEngine: SpeechEngine, @unchecked Sendable {
        let id = "unavailable"
        let displayName = "Unavailable"
        let supportsRecognitionBias = false
        let unavailability: EngineUnavailability? = .shaderLibraryUnloadable
        func loadIfNeeded() async throws { throw Refused() }
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { throw Refused() }
        func evict() async {}
    }

    @Test func anUnavailableEngineIsSkippedNotFailed() async {
        let result = await ModelSelfTestRunner.verify(
            UnavailableEngine(), clipURL: URL(fileURLWithPath: "/dev/null")
        ) { _, _ in throw Refused() }
        #expect(result == nil)
    }
}
