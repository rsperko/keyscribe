import Foundation
import KeyScribeKit

// Runs the post-install smoke test against any engine: transcribe the bundled known clip and check
// its distinctive words came back (`ModelSelfTest`). Engine-agnostic — covers Parakeet, Whisper, and
// Apple identically. Returns nil when the clip isn't bundled (e.g. `swift run` / tests) so a missing
// asset degrades to "skip", never a false failure.
enum ModelSelfTestRunner {
    static let expectedWords = ["quick", "brown", "fox"]
    static let minMatches = 2

    // "Engine busy, don't judge it" — mapped to nil (skip), never false, so a collision with a live
    // dictation can't fail a good model.
    struct Skipped: Error {}

    static var clipURL: URL? {
        Bundle.main.url(forResource: "model-selftest", withExtension: "wav")
    }

    // transcribe is injected so the caller can serialize it against live dictation on the same non-actor
    // engine instance; a bare engine.transcribe here would race it.
    static func verify(
        _ engine: any SpeechEngine, transcribe: @Sendable (URL, [String]) async throws -> String
    ) async -> Bool? {
        guard let url = clipURL else {
            Log.models.notice("self-test \(engine.id, privacy: .public): skipped (no bundled clip)")
            return nil
        }
        do {
            let text = try await transcribe(url, [])
            let passed = ModelSelfTest.passes(transcript: text, expectedWords: expectedWords, minMatches: minMatches)
            Log.models.notice("self-test \(engine.id, privacy: .public): \(passed ? "passed" : "failed", privacy: .public)")
            return passed
        } catch is Skipped {
            Log.models.notice("self-test \(engine.id, privacy: .public): skipped (engine busy)")
            return nil
        } catch {
            Log.models.error("self-test \(engine.id, privacy: .public): error \(error, privacy: .public)")
            return false
        }
    }
}
