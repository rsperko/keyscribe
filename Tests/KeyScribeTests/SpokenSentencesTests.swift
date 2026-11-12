import Testing
@testable import KeyScribeApp

struct SpokenSentencesTests {
    @Test func anAnswerIsReadOneSentenceAtATime() {
        #expect(SpokenSentences.split("Reply by Friday. Then ship it! Questions? Ask Dana.")
            == ["Reply by Friday.", "Then ship it!", "Questions? Ask Dana."])
    }

    @Test func anAbbreviationDecimalOrInitialismDoesNotEndASentence() {
        #expect(SpokenSentences.split("Please contact Dr. Smith about it. Then ship the release.")
            == ["Please contact Dr. Smith about it.", "Then ship the release."])
        #expect(SpokenSentences.split("The U.S. Government replied today. It agreed with us.")
            == ["The U.S. Government replied today.", "It agreed with us."])
        #expect(SpokenSentences.split("Version 3.2 fixed it, e.g. the crash. It shipped today.")
            == ["Version 3.2 fixed it, e.g. the crash.", "It shipped today."])
    }

    @Test func aLineBreakEndsASentence() {
        #expect(SpokenSentences.split("First line without a period\nSecond line here.")
            == ["First line without a period", "Second line here."])
    }

    @Test func oneSentenceOrNoneStaysWhole() {
        #expect(SpokenSentences.split("Reply by Friday.") == ["Reply by Friday."])
        #expect(SpokenSentences.split("  ") == [])
    }
}
