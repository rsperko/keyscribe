import Testing
@testable import KeyScribeKit

struct HeardExcerptTests {
    @Test func quotesTheHeardPhrase() {
        #expect(HeardExcerpt(heard: "which to Mail")?.text == "Heard \u{201C}which to Mail\u{201D}")
    }

    @Test func nothingDisplayableGivesNoExcerpt() {
        #expect(HeardExcerpt(heard: "") == nil)
        #expect(HeardExcerpt(heard: " \n\t ") == nil)
    }

    @Test func foldsLineBreaksAndRepeatedSpaces() {
        #expect(HeardExcerpt(heard: "  switch\n\nto   Mail \t")?.text == "Heard \u{201C}switch to Mail\u{201D}")
    }

    @Test func aPhraseAtTheBudgetIsKeptWhole() {
        let phrase = String(repeating: "a", count: HeardExcerpt.characterBudget)
        #expect(HeardExcerpt(heard: phrase)?.text == "Heard \u{201C}\(phrase)\u{201D}")
    }

    @Test func aLongerPhraseKeepsItsStartAndEndsInOneEllipsisWithoutAClosingQuote() {
        let phrase = String(repeating: "b", count: HeardExcerpt.characterBudget) + " tail"
        #expect(HeardExcerpt(heard: phrase)?.text == "Heard \u{201C}\(String(repeating: "b", count: HeardExcerpt.characterBudget))\u{2026}")
    }

    @Test func shorteningDoesNotStackOnTheSpeakersOwnEllipsis() {
        let phrase = String(repeating: "c", count: HeardExcerpt.characterBudget - 3) + "... and more"
        #expect(HeardExcerpt(heard: phrase)?.text
                == "Heard \u{201C}\(String(repeating: "c", count: HeardExcerpt.characterBudget - 3))\u{2026}")
        let comma = String(repeating: "e", count: HeardExcerpt.characterBudget - 2) + ", and more"
        #expect(HeardExcerpt(heard: comma)?.text
                == "Heard \u{201C}\(String(repeating: "e", count: HeardExcerpt.characterBudget - 2))\u{2026}")
        let question = String(repeating: "f", count: HeardExcerpt.characterBudget - 1) + "? more"
        #expect(HeardExcerpt(heard: question)?.text
                == "Heard \u{201C}\(String(repeating: "f", count: HeardExcerpt.characterBudget - 1))\u{2026}")
        let spaced = String(repeating: "d", count: HeardExcerpt.characterBudget - 1) + " and more"
        #expect(HeardExcerpt(heard: spaced)?.text
                == "Heard \u{201C}\(String(repeating: "d", count: HeardExcerpt.characterBudget - 1))\u{2026}")
    }

    @Test func countsGraphemesSoWideCharactersAndEmojiAreNeverSplit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let phrase = String(repeating: family, count: HeardExcerpt.characterBudget + 2)
        let text = HeardExcerpt(heard: phrase)?.text ?? ""
        #expect(text == "Heard \u{201C}\(String(repeating: family, count: HeardExcerpt.characterBudget))\u{2026}")
        let kanji = String(repeating: "\u{8A71}", count: 10)
        #expect(HeardExcerpt(heard: kanji)?.text == "Heard \u{201C}\(kanji)\u{201D}")
    }
}
