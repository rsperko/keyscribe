import Foundation
import Testing
@testable import KeyScribeKit

struct RegexCacheTests {
    @Test func samePatternReturnsTheSameCompiledInstance() {
        let a = RegexCache.regex(#"\d{3}-\d{4}"#)
        let b = RegexCache.regex(#"\d{3}-\d{4}"#)
        #expect(a != nil)
        #expect(a === b)   // memoized, not recompiled
    }

    @Test func invalidPatternReturnsNil() {
        #expect(RegexCache.regex("(unclosed") == nil)
    }

    @Test func routingSafetyRejectsAPatternAlreadyCompiledForAnotherUse() {
        let pattern = #"(a+)+$-routing-safety"#
        #expect(RegexCache.regex(pattern, options: [.caseInsensitive]) != nil)
        #expect(RegexCache.routingRegex(pattern, options: [.caseInsensitive]) == nil)
        #expect(!RegexCache.isKnownInvalid(pattern, options: [.caseInsensitive]))
    }

    @Test func invalidPatternIsMemoizedAsFailed() {
        let pattern = "(still-unclosed-\(#function)"
        #expect(!RegexCache.isKnownInvalid(pattern))
        #expect(RegexCache.regex(pattern) == nil)
        #expect(RegexCache.isKnownInvalid(pattern))
    }

    @Test func differentOptionsAreCachedSeparately() {
        let plain = RegexCache.regex("a.b")
        let dotAll = RegexCache.regex("a.b", options: [.dotMatchesLineSeparators])
        #expect(plain !== dotAll)
    }

    @Test func isValidPatternReportsValidityWithoutMemoizing() {
        let valid = "cat(?:s)?-\(#function)"
        let invalid = "(unclosed-\(#function)"
        #expect(RegexCache.isValidPattern(valid))
        #expect(!RegexCache.isValidPattern(invalid))
        #expect(!RegexCache.isKnownInvalid(invalid))   // not memoized
    }

    @Test func compiledRegexStillMatches() {
        let re = RegexCache.regex(#"\bcat\b"#)
        let text = "the cat sat"
        #expect(re?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
    }
}
