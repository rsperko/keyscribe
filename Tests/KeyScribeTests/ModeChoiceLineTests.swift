import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ModeChoiceLineTests {
    @Test func mapsEveryReasonToUserLanguage() {
        #expect(ModeChoiceLine.text(reason: .oneShot, routedPhrase: nil, triggerDisplay: nil)
            == "Chosen from the menu for this dictation")
        #expect(ModeChoiceLine.text(reason: .contextRule, routedPhrase: nil, triggerDisplay: nil)
            == "Chosen for the app you were in")
        #expect(ModeChoiceLine.text(reason: .fallback, routedPhrase: nil, triggerDisplay: nil)
            == "Plain Dictation — nothing else matched")
    }

    @Test func triggerKeyAppendsTheKeyWhenKnown() {
        #expect(ModeChoiceLine.text(reason: .triggerKey, routedPhrase: nil, triggerDisplay: "Right-⌥")
            == "Started by its shortcut (Right-⌥)")
        #expect(ModeChoiceLine.text(reason: .triggerKey, routedPhrase: nil, triggerDisplay: nil)
            == "Started by its shortcut")
    }

    @Test func spokenPhraseQuotesThePhrase() {
        #expect(ModeChoiceLine.text(reason: .spokenPhrase, routedPhrase: "as an email", triggerDisplay: nil)
            == "Routed by the spoken phrase \u{201C}as an email\u{201D}")
        #expect(ModeChoiceLine.text(reason: .spokenPhrase, routedPhrase: nil, triggerDisplay: nil)
            == "Routed by a spoken phrase")
    }

    @Test func nilReasonProducesNoLine() {
        #expect(ModeChoiceLine.text(reason: nil, routedPhrase: nil, triggerDisplay: nil) == nil)
    }
}
