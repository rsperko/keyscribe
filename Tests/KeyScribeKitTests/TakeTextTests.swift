import Foundation
import Testing
@testable import KeyScribeKit

struct TakeTextTests {
    private func pipeline(_ rules: [ReplacementRule] = []) -> Pipeline {
        TakeStages.dictation(
            text: TakeStages.text(liveEdits: true, rules: rules, numbers: false, dictionary: []),
            clipboard: nil, redaction: false)
    }

    @Test func aWholeUtteranceRuleIsTheTextAsWrittenUntrimmed() throws {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume.", isRegex: false)]
        let take = TakeText("slash resume", pipeline: pipeline(rules), trimsTrailingPunctuation: true)
        #expect(try #require(take.bare).text == "/resume.")
        #expect(take.localText == "/resume.")
    }

    @Test func trailingPunctuationIsTrimmedBeforeVerbatimIsRestored() {
        let take = TakeText("note begin verbatim v1.2. end verbatim", pipeline: pipeline(), trimsTrailingPunctuation: true)
        #expect(take.localText == "note v1.2.")
        #expect(TakeText("hello there.", pipeline: pipeline(), trimsTrailingPunctuation: true).localText == "hello there")
    }

    @Test func modelOutputIsFinishedTheSameWay() {
        let take = TakeText("begin verbatim a.b end verbatim", pipeline: pipeline(), trimsTrailingPunctuation: true)
        let token = take.payload.text.trimmingCharacters(in: .whitespaces)
        #expect(take.finish("Sure: \(token).") == "Sure: a.b")
    }

    @Test func anIssuedTokenThatSurvivesRestoreIsALeak() {
        let take = TakeText("begin verbatim x end verbatim", pipeline: pipeline(), trimsTrailingPunctuation: false)
        let token = take.payload.issuedTokens[0]
        #expect(take.leaksIssuedToken("still \(token)"))
        #expect(!take.leaksIssuedToken("⟦SN:VERB:99⟧ is just text"))
    }

    @Test func onlyATokenThisTakeIssuedCountsAsALeak() {
        #expect(TakeText.leaksIssuedToken("literal ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:1⟧"]))
        #expect(!TakeText.leaksIssuedToken("literal ⟦SN:REDACT:1⟧", issuedTokens: ["⟦SN:REDACT:2⟧"]))
    }

    @Test func nothingLeftAfterTheStagesIsBlank() {
        #expect(TakeText("  ", pipeline: pipeline(), trimsTrailingPunctuation: false).isBlank)
        #expect(!TakeText("hi", pipeline: pipeline(), trimsTrailingPunctuation: false).isBlank)
    }
}
