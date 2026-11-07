import Foundation
import KeyScribeKit
import Testing

struct HistoryRewriteAgainTests {
    private func fallback(id: String? = "a", heard: String = "teh plan", summary: String? = nil) -> HistoryEntry {
        var entry = HistoryEntry(
            id: id, timestamp: Date(timeIntervalSince1970: 1_000), modeName: "Email", heard: heard,
            transformed: "the plan", result: "the plan.", outcome: .localFallback, cloudInvolved: true,
            redaction: false, contextCategories: ["app"], connection: "Fast", model: "m1", prompt: "old prompt",
            fallbackReason: "HTTP 503")
        entry.rewriteSkippedMs = nil
        entry.summary = summary
        return entry
    }

    @Test func onlyAFallbackDictationWithAnIdAndWordsCanBeRewrittenAgain() {
        #expect(fallback().canRewriteAgain)
        #expect(!fallback(id: nil).canRewriteAgain)
        #expect(!fallback(heard: "").canRewriteAgain)
        #expect(!fallback(summary: "Sent to backend").canRewriteAgain)
        var inserted = fallback()
        inserted.outcome = .inserted
        #expect(!inserted.canRewriteAgain)
    }

    @Test func aRewriteAgainReplacesTheResultAndSaysItWasNotInserted() throws {
        let rewritten = fallback().rewrittenAgain(
            "The plan.", connection: "Smart", model: "m2", redaction: true, prompt: "new prompt",
            received: "The plan.", reasoning: "Off")
        #expect(rewritten.result == "The plan.")
        #expect(rewritten.outcome == .rewrittenLater)
        #expect(rewritten.transformed == "the plan")
        #expect(rewritten.connection == "Smart")
        #expect(rewritten.model == "m2")
        #expect(rewritten.redaction)
        #expect(rewritten.prompt == "new prompt")
        #expect(rewritten.received == "The plan.")
        #expect(rewritten.reasoning == "Off")
        #expect(rewritten.contextCategories.isEmpty)
        #expect(rewritten.fallbackReason == "HTTP 503")
        #expect(!rewritten.keptLocalText)
        #expect(!rewritten.canRewriteAgain)
        #expect(!rewritten.outcome.isCommand)
        let decoded = try HistoryEntry(jsonLine: try rewritten.jsonLine())
        #expect(decoded.outcome == .rewrittenLater)
    }
}
