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

    @Test func differentOptionsAreCachedSeparately() {
        let plain = RegexCache.regex("a.b")
        let dotAll = RegexCache.regex("a.b", options: [.dotMatchesLineSeparators])
        #expect(plain !== dotAll)
    }

    @Test func compiledRegexStillMatches() {
        let re = RegexCache.regex(#"\bcat\b"#)
        let text = "the cat sat"
        #expect(re?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
    }
}
