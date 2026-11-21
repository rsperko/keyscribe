import Foundation
import Testing
@testable import KeyScribeKit

struct SpokenNumberTests {
    private func words(_ said: String) -> [String] {
        AgentHandles.normalize(said).split(separator: " ").map(String.init)
    }

    @Test(arguments: [
        ("61", 61, 1), ("sixty one", 61, 2), ("two hundred fifty", 250, 3), ("one hundred and five", 105, 4),
        ("twelve", 12, 1), ("six", 6, 1), ("zero", 0, 1), ("one thousand two hundred", 1200, 4), ("1234", 1234, 1),
    ])
    func aWholeNumberIsReadAsSaid(said: String, value: Int, count: Int) {
        #expect(SpokenNumber.read(words(said)[...], forms: [.whole]) == .init(value: value, words: count))
    }

    @Test(arguments: [("two fifty", 250, 2), ("2 50", 250, 2), ("twelve thirty four", 1234, 3), ("nine ninety nine", 999, 3)])
    func aGroupedNumberJoinsItsGroups(said: String, value: Int, count: Int) {
        #expect(SpokenNumber.read(words(said)[...], forms: [.grouped]) == .init(value: value, words: count))
        #expect(SpokenNumber.read(words(said)[...], forms: [.whole]) == .init(value: nil, words: count))
    }

    @Test(arguments: [("two four zero", 240, 3), ("2 4 0", 240, 3), ("one 2", 12, 2)])
    func digitsSaidOneByOneJoin(said: String, value: Int, count: Int) {
        #expect(SpokenNumber.read(words(said)[...], forms: [.digits]) == .init(value: value, words: count))
    }

    @Test(arguments: [
        ("61 tests are failing", 61, 1), ("two things are broken", 2, 1), ("sixty one, then", 61, 2),
        ("one hundred and five and more", 105, 4), ("two fifty percent", 250, 2), ("61 and one more thing", 61, 1),
        ("two forty and two other bugs", 240, 2), ("two hundred and fifty and one", 250, 4),
    ])
    func theRunEndsAtTheFirstWordThatIsNotPartOfANumber(said: String, value: Int, count: Int) {
        #expect(SpokenNumber.read(words(said)[...], forms: [.whole, .grouped]) == .init(value: value, words: count))
    }

    @Test(arguments: ["six eight", "68 2", "two three", "sixty one five", "fifty sixty one hundred", "two hundred thousand hundred"])
    func aRunNoAcceptedFormReadsWholeIsUnreadableNotShortened(said: String) {
        let read = SpokenNumber.read(words(said)[...], forms: [.whole, .grouped])
        #expect(read?.value == nil)
        #expect(read?.words == words(said).count)
    }

    @Test(arguments: [("1 hundred", 100, 2), ("2 hundred 50", 250, 3), ("sixty 1", 61, 2), ("60 one", 61, 2), ("3 thousand 4 hundred", 3400, 4)])
    func numeralsAndNumberWordsMixInAWholeNumber(said: String, value: Int, count: Int) {
        #expect(SpokenNumber.read(said.split(separator: " ").map(String.init)[...], forms: [.whole]) == .init(value: value, words: count))
    }

    @Test(arguments: ["007 5", "00 00", "12 3"])
    func digitsSaidOneByOneTakeOnlySingleDigitNumerals(said: String) {
        #expect(SpokenNumber.read(said.split(separator: " ").map(String.init)[...], forms: [.digits])?.value == nil)
    }

    @Test func noRunIsReadByTwoForms() {
        let vocabulary = ["zero", "one", "two", "nine", "ten", "twelve", "twenty", "ninety", "hundred", "thousand", "and", "0", "1", "7", "50", "99", "07"]
        var both: [String] = []
        for first in vocabulary { for second in vocabulary + [""] { for third in vocabulary + [""] {
            let run = [first, second, third].filter { !$0.isEmpty }
            let readers = [SpokenNumber.Form.whole, .grouped, .digits].filter { SpokenNumber.read(run[...], forms: [$0])?.value != nil }
            if readers.count > 1 { both.append(run.joined(separator: " ")) }
        } } }
        #expect(both.isEmpty, "\(both.prefix(20))")
        #expect(SpokenNumber.read(words("two four")[...], forms: [.whole, .grouped, .digits]) == .init(value: 24, words: 2))
    }

    @Test(arguments: ["there are 99", "hundred things", "and two", "to the tests", "for now", ""])
    func wordsThatDoNotStartANumberAreNotOne(said: String) {
        #expect(SpokenNumber.read(words(said)[...], forms: [.whole, .grouped, .digits]) == nil)
    }

    @Test func aRunTooLongForAnIntegerIsUnreadableRatherThanACrash() {
        let long = Array(repeating: "nine", count: 40)
        #expect(SpokenNumber.read(long[...], forms: [.digits]) == .init(value: nil, words: 40))
        #expect(SpokenNumber.read(["99999999999999999999999"][...], forms: [.whole]) == .init(value: nil, words: 1))
    }
}
