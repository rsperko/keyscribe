import Foundation
import KeyScribeKit

// Runs the post-install smoke test against any engine: transcribe the bundled known clip and check
// its distinctive words came back (`ModelSelfTest`). Engine-agnostic — covers Parakeet, Whisper, and
// Apple identically. Returns nil when the clip isn't bundled (e.g. `swift run` / tests) so a missing
// asset degrades to "skip", never a false failure.
enum ModelSelfTestRunner {
    static let expectedWords = ["quick", "brown", "fox"]
    static let minMatches = 2

    static var clipURL: URL? {
        Bundle.main.url(forResource: "model-selftest", withExtension: "wav")
    }

    static func verify(_ engine: any SpeechEngine) async -> Bool? {
        guard let url = clipURL else {
            Log.models.notice("self-test \(engine.id, privacy: .public): skipped (no bundled clip)")
            return nil
        }
        do {
            let text = try await engine.transcribe(wavURL: url, biasTerms: [])
            let passed = ModelSelfTest.passes(transcript: text, expectedWords: expectedWords, minMatches: minMatches)
            Log.models.notice("self-test \(engine.id, privacy: .public): \(passed ? "passed" : "failed", privacy: .public)")
            return passed
        } catch {
            Log.models.error("self-test \(engine.id, privacy: .public): error \(error, privacy: .public)")
            return false
        }
    }
}
