import Testing
@testable import KeyScribeKit

private func itn(_ s: String) -> String { InverseTextNormalizer.apply(s) }

struct InverseTextNormalizerTests {
    @Test func convertsCompoundCardinals() {
        #expect(itn("twenty five") == "25")
        #expect(itn("one hundred twenty three") == "123")
        #expect(itn("three thousand") == "3000")
        #expect(itn("five thousand two hundred") == "5200")
        #expect(itn("ten") == "10")
    }

    @Test func leavesSmallStandaloneNumbersAsWords() {
        #expect(itn("I have one cat") == "I have one cat")
        #expect(itn("give me five") == "give me five")
    }

    @Test func preservesYearIdioms() {
        #expect(itn("twenty twenty six") == "twenty twenty six")
        #expect(itn("nineteen ninety five") == "nineteen ninety five")
    }

    @Test func bailsOnAmbiguousRuns() {
        #expect(itn("twenty fifteen") == "twenty fifteen")
        #expect(itn("five fifteen") == "five fifteen")
    }

    @Test func keepsSurroundingText() {
        #expect(itn("about twenty five people came") == "about 25 people came")
        #expect(itn("send twenty five and thirty two") == "send 25 and 32")
    }

    @Test func leavesNumbersWithAttachedPunctuationUntouchedRun() {
        #expect(itn("the answer is forty two.") == "the answer is 42.")
    }

    @Test func noNumberWordsUnchanged() {
        #expect(itn("just plain words here") == "just plain words here")
    }
}
