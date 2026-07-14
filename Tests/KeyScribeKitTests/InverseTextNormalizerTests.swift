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

    @Test func convertsDecimals() {
        #expect(itn("three point one four") == "3.14")
        #expect(itn("three point five") == "3.5")
        #expect(itn("zero point five") == "0.5")
        #expect(itn("one hundred point five") == "100.5")
        #expect(itn("the value is forty two point five.") == "the value is 42.5.")
    }

    @Test func leavesBareOrIncompleteDecimalsAlone() {
        #expect(itn("point five") == "point five")
        #expect(itn("five point") == "five point")
        #expect(itn("that is a fair point") == "that is a fair point")
    }

    @Test func convertsPercent() {
        #expect(itn("fifty percent") == "50%")
        #expect(itn("one hundred percent") == "100%")
        #expect(itn("five percent") == "5%")
        #expect(itn("about fifty percent off") == "about 50% off")
    }

    @Test func convertsOrdinals() {
        #expect(itn("twenty first") == "21st")
        #expect(itn("twenty second") == "22nd")
        #expect(itn("twenty third") == "23rd")
        #expect(itn("one hundredth") == "100th")
        #expect(itn("eleventh") == "11th")
        #expect(itn("thirteenth") == "13th")
        #expect(itn("twentieth") == "20th")
    }

    @Test func leavesSmallStandaloneOrdinalsAsWords() {
        #expect(itn("first of all") == "first of all")
        #expect(itn("the third option") == "the third option")
    }

    @Test func convertsSignedNumbers() {
        #expect(itn("minus five") == "-5")
        #expect(itn("negative five") == "-5")
        #expect(itn("the temperature is minus ten") == "the temperature is -10")
    }

    @Test func leavesSignWordsWithoutNumbersAlone() {
        #expect(itn("a negative attitude") == "a negative attitude")
        #expect(itn("ten minus five") == "10 minus five")
    }

    @Test func composesSignDecimalAndPercent() {
        #expect(itn("minus twenty point five percent") == "-20.5%")
    }

    @Test func signDoesNotCrossSentenceBoundary() {
        #expect(itn("The test came back negative. Twenty people were tested")
            == "The test came back negative. 20 people were tested")
        #expect(itn("Subtract them and you get minus. Fifty remain")
            == "Subtract them and you get minus. 50 remain")
    }

    @Test func convertsLargeScaleCardinals() {
        #expect(itn("two million") == "2000000")
        #expect(itn("one billion") == "1000000000")
        #expect(itn("three million five hundred thousand") == "3500000")
    }

    @Test func convertsScaleOrdinals() {
        #expect(itn("one thousandth") == "1000th")
        #expect(itn("millionth") == "1000000th")
        #expect(itn("twelfth") == "12th")
    }

    @Test func leavesSmallSecondOrdinalAsWord() {
        #expect(itn("a second chance") == "a second chance")
    }

    @Test func decimalKeepsMultiTokenIntegerAndSign() {
        #expect(itn("twenty five point five") == "25.5")
        #expect(itn("minus zero point five") == "-0.5")
    }

    @Test func percentOnTeen() {
        #expect(itn("fifteen percent") == "15%")
    }

    @Test func percentDoesNotCrossSentenceBoundary() {
        #expect(itn("The odds are fifty. Percent signs confuse people")
            == "The odds are 50. Percent signs confuse people")
    }

    @Test func percentDoesNotCrossPunctuatedDecimal() {
        #expect(itn("three point five. Percent") == "3.5. Percent")
    }

    @Test func decimalPointDoesNotCrossSentenceBoundary() {
        #expect(itn("We were up by one point. Five minutes later they tied it.")
            == "We were up by one point. Five minutes later they tied it.")
        #expect(itn("The score was twenty one point. Five seconds remained.")
            == "The score was 21 point. Five seconds remained.")
    }

    @Test func isCaseInsensitive() {
        #expect(itn("Twenty Five") == "25")
        #expect(itn("Fifty Percent") == "50%")
    }

    @Test func bareDecoratorWordsWithoutNumbersUnchanged() {
        #expect(itn("percent done") == "percent done")
    }

    @Test func connectorAndSplitsTheNumberRun() {
        #expect(itn("one hundred and twenty three") == "100 and 23")
    }

    @Test func convertsHyphenatedCompoundCardinals() {
        #expect(itn("sixty-five") == "65")
        #expect(itn("twenty-five") == "25")
        #expect(itn("sixty-five million") == "65000000")
        #expect(itn("I'm talking about the sixty-five million changes.")
            == "I'm talking about the 65000000 changes.")
    }

    @Test func convertsHyphenatedOrdinals() {
        #expect(itn("twenty-first") == "21st")
    }

    @Test func leavesHyphenatedNonNumbersUntouched() {
        #expect(itn("a well-known fact") == "a well-known fact")
        #expect(itn("state-of-the-art design") == "state-of-the-art design")
    }
}
