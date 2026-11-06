import Foundation
import Testing
@testable import KeyScribeKit

struct TakeStagesTests {
    private func text(liveEdits: Bool = true, dictionary: [String] = []) -> [any PipelineStage] {
        TakeStages.text(
            liveEdits: liveEdits, rules: [ReplacementRule(heard: "teh", replace: "the", isRegex: false)], numbers: false,
            dictionary: dictionary)
    }

    @Test func theTextStagesRunLiveEditsReplacementsAndTheDictionary() {
        let pipeline = Pipeline(text(dictionary: ["Kubernetes"]))
        #expect(pipeline.restore(pipeline.forward("teh kabernetas cluster insert new line ok").text) == "the Kubernetes cluster\nok")
    }

    @Test func anEmptyDictionaryAddsNoStage() {
        #expect(text(dictionary: []).count == text(dictionary: ["Kubernetes"]).count - 1)
    }

    @Test func dictationWithLiveEditsProtectsVerbatimAndReadsTheClipboardOnlyWhenAsked() {
        let reads = Counter()
        let pipeline = TakeStages.dictation(text: text(), clipboard: { reads.bump(); return "X" }, redaction: false)
        #expect(pipeline.restore(pipeline.forward("begin verbatim teh end verbatim teh").text) == "teh the")
        #expect(reads.count == 0)
        #expect(pipeline.restore(pipeline.forward("paste insert clipboard contents").text) == "paste X")
        #expect(reads.count == 1)
    }

    @Test func dictationWithoutLiveEditsHasNoVerbatimOrClipboard() {
        let pipeline = TakeStages.dictation(text: text(liveEdits: false), clipboard: { "X" }, redaction: false)
        #expect(pipeline.forward("begin verbatim insert clipboard contents end verbatim").issuedTokens.isEmpty)
    }

    @Test func dictationRedactsOnlyWhenAsked() {
        let plain = TakeStages.dictation(text: text(), clipboard: nil, redaction: false)
        let redacted = TakeStages.dictation(text: text(), clipboard: nil, redaction: true)
        #expect(plain.forward("mail alice@example.com").issuedTokens.isEmpty)
        #expect(redacted.forward("mail alice@example.com").issuedTokens.count == 1)
    }

    @Test func aSelectionRunsOnlyTheTokenizersAndSharesTheRedactionTokenizer() {
        let shared = Tokenizer()
        let pipeline = TakeStages.selection(liveEdits: true, redaction: shared)
        let payload = pipeline.forward("begin verbatim teh end verbatim teh alice@example.com")
        #expect(payload.issuedTokens.count == 2)
        #expect(pipeline.restore(payload.text) == "teh teh alice@example.com")
        #expect(shared.issuedTokens.count == 1)
    }

    @Test func aSelectionWithoutPrivacyHasNoRedaction() {
        #expect(TakeStages.selection(liveEdits: false, redaction: nil).forward("alice@example.com").issuedTokens.isEmpty)
    }

    @Test func withoutTheDictionaryDropsOnlyTheDictionaryStage() {
        let pipeline = Pipeline(TakeStages.withoutDictionary(text(dictionary: ["Kubernetes"])))
        #expect(pipeline.restore(pipeline.forward("teh kabernetas").text) == "the kabernetas")
    }

    private final class Counter: @unchecked Sendable {
        private(set) var count = 0
        func bump() { count += 1 }
    }
}
