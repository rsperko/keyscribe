import Testing
@testable import KeyScribeKit

struct SpokenNameMatchTests {
    let long = "foo jk boots manager 1234"

    @Test func exactIgnoresSpacingAndCase() {
        #expect(SpokenNameMatch.exact.matches("back end", "Backend"))
        #expect(SpokenNameMatch.exact.matches("KeyscribeBlue", "keyscribe blue"))
        #expect(!SpokenNameMatch.exact.matches("keyscribe", "keyscribe blue"))
    }

    @Test func partialIsARunOfTheNamesWordsInOrder() {
        #expect(SpokenNameMatch.partial.matches("jk boots", long))
        #expect(SpokenNameMatch.partial.matches("boots manager", long))
        #expect(!SpokenNameMatch.partial.matches("boots jk", long))
        #expect(!SpokenNameMatch.partial.matches(long, long))
    }

    @Test func wordsAreAnyOfTheNamesWordsInAnyOrder() {
        #expect(SpokenNameMatch.words.matches("boots jk", long))
        #expect(SpokenNameMatch.words.matches("manager foo", long))
        #expect(!SpokenNameMatch.words.matches("boots fix", long))
        #expect(!SpokenNameMatch.words.matches("jk", long))
    }

    @Test func theLongestLeadingSpanWins() {
        let names = ["jk boots", long]
        #expect(SpokenNameMatch.leading(["jk", "boots", "manager", "fix", "it"], names: names) == .init(length: 3, names: [long]))
        #expect(SpokenNameMatch.leading(["jk", "boots", "fix", "it"], names: names) == .init(length: 2, names: ["jk boots"]))
        #expect(SpokenNameMatch.leading(["boots", "jk", "fix"], names: names) == .init(length: 2, names: ["jk boots", long]))
    }

    @Test func aSpanMatchingSeveralNamesReturnsThemAll() {
        let names = ["jk boots manager", "mk boots", "frontend"]
        #expect(SpokenNameMatch.leading(["boots", "fix", "it"], names: names) == .init(length: 1, names: ["jk boots manager", "mk boots"]))
    }

    @Test func aSpanEndsAtTheFirstWordThatCannotBelong() {
        #expect(SpokenNameMatch.leading(["run", "the", "tests"], names: [long]) == nil)
        #expect(SpokenNameMatch.leading(["boots", "manager"], names: [long], limit: 1) == .init(length: 1, names: [long]))
    }

    @Test func aLeadingSpanUsesEachWordOfTheNameOnce() {
        #expect(SpokenNameMatch.leading(["release", "manager", "release", "the", "package"], names: ["release manager"]) == .init(length: 2, names: ["release manager"]))
        #expect(SpokenNameMatch.leading(["build", "build", "the", "project"], names: ["build"]) == .init(length: 1, names: ["build"]))
        #expect(SpokenNameMatch.words.matches("build build", "build"))
    }

    @Test func aLooseMatchCanRequireMoreWordsThanAnExactOne() {
        let names = ["backend", long]
        let strict: (SpokenNameMatch) -> Int = { $0 == .exact ? 1 : 2 }
        #expect(SpokenNameMatch.leading(["boots", "fix"], names: names, minimumWords: strict) == nil)
        #expect(SpokenNameMatch.leading(["boots", "jk", "fix"], names: names, minimumWords: strict) == .init(length: 2, names: [long]))
        #expect(SpokenNameMatch.leading(["backend", "fix"], names: names, minimumWords: strict) == .init(length: 1, names: ["backend"]))
    }
}
