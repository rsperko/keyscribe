import Testing
@testable import KeyScribeKit

struct ReplacementSafetyTests {
    @Test func acceptsOrdinaryPatterns() {
        #expect(ReplacementSafety.isSafe(#"\d{4}"#))
        #expect(ReplacementSafety.isSafe(#"foo|bar"#))
        #expect(ReplacementSafety.isSafe(#"(ab)+"#))
        #expect(ReplacementSafety.isSafe(#"\bword\b"#))
        #expect(ReplacementSafety.isSafe(#"colou?r"#))
        #expect(ReplacementSafety.isSafe(#"a.*b"#))
        #expect(ReplacementSafety.isSafe(#"(foo|bar){2,4}"#))
        #expect(ReplacementSafety.isSafe(#"[a-z]+@[a-z]+"#))
        #expect(ReplacementSafety.isSafe(#"\(\d+\)"#))           // escaped parens, not a group
    }

    @Test func rejectsNestedQuantifiers() {
        #expect(!ReplacementSafety.isSafe(#"(a+)+$"#))
        #expect(!ReplacementSafety.isSafe(#"(a*)*"#))
        #expect(!ReplacementSafety.isSafe(#"(.*)+"#))
        #expect(!ReplacementSafety.isSafe(#"(a+)*"#))
        #expect(!ReplacementSafety.isSafe(#"([a-z]+)+"#))
        #expect(!ReplacementSafety.isSafe(#"(a{1,})+"#))
        #expect(!ReplacementSafety.isSafe(#"((ab)+)+"#))
    }

    @Test func rejectsRepeatWrappedInAnExtraGroup() {
        #expect(!ReplacementSafety.isSafe(#"((a+))*"#))
        #expect(!ReplacementSafety.isSafe(#"(?:(a+))+"#))
        #expect(!ReplacementSafety.isSafe(#"((a+)b?)*"#))
    }

    @Test func rejectsBoundedCountedRepeatOfAmbiguousGroup() {
        #expect(!ReplacementSafety.isSafe(#"(a+){2,999}"#))
        #expect(!ReplacementSafety.isSafe(#"(a+){2}"#))
    }

    @Test func rejectsNullableGroupUnderCountedQuantifier() {
        #expect(!ReplacementSafety.isSafe(#"(a?){25}b"#))
        #expect(!ReplacementSafety.isSafe(#"(a{0,1}){25}b"#))
        #expect(!ReplacementSafety.isSafe(#"(a?)*b"#))
        #expect(!ReplacementSafety.isSafe(#"(a?)+b"#))
        #expect(!ReplacementSafety.isSafe(#"(\w?){20}x"#))
        #expect(!ReplacementSafety.isSafe(#"(a{0}){25}b"#))
    }

    @Test func acceptsOptionalOutsideAQuantifiedGroup() {
        #expect(ReplacementSafety.isSafe(#"https?://x"#))
        #expect(ReplacementSafety.isSafe(#"a?b?c?"#))
        #expect(ReplacementSafety.isSafe(#"(ab)?"#))
        #expect(ReplacementSafety.isSafe(#"(a{1,1}){25}"#))
    }

    @Test func bracketedQuantifierCharsAreLiteral() {
        #expect(ReplacementSafety.isSafe(#"[+*]+"#))             // + and * inside class are literal
    }

    @Test func rejectsOverlappingAlternationUnderRepetition() {
        #expect(!ReplacementSafety.isSafe(#"(a|aa)+$"#))
        #expect(!ReplacementSafety.isSafe(#"(a|a)*"#))
        #expect(!ReplacementSafety.isSafe(#"(foo|foobar|bar)+"#))
        #expect(!ReplacementSafety.isSafe(#"((a|aa)+)+"#))
        #expect(!ReplacementSafety.isSafe(#"(a|)+"#))            // empty branch is nullable
    }

    // Replacement regexes compile .caseInsensitive (ReplacementsStage.prepare), so branches that differ
    // only by case are the SAME branch to the matcher: `(ab|AB)+` backtracks exponentially even though it
    // reads as prefix-free. Fold before comparing.
    @Test func rejectsAlternationThatOnlyLooksPrefixFreeBeforeCaseFolding() {
        #expect(!ReplacementSafety.isSafe(#"(ab|AB)+"#))
        #expect(!ReplacementSafety.isSafe(#"(a|A)+$"#))
        #expect(!ReplacementSafety.isSafe(#"(foo|FOOBAR)+"#))
    }

    // ICU folds further than lowercasing does: /ß/i matches "SS", /ſ/i matches "s", /ﬃ/i matches "ffi".
    // Each pair is therefore one branch to the matcher, and each measured exponential against ICU
    // (`(ß|SS)+$` reached 195 ms at 20 repetitions) while looking prefix-free by spelling.
    @Test func rejectsBranchesThatOnlyDifferByUnicodeCaseFolding() {
        #expect(!ReplacementSafety.isSafe(#"(ß|SS)+$"#))
        #expect(!ReplacementSafety.isSafe(#"(ſ|s)+"#))
        #expect(!ReplacementSafety.isSafe(#"(ﬃ|ffi)+"#))
    }

    @Test func rejectsOverlappingAlternationUnderCountedQuantifiers() {
        #expect(!ReplacementSafety.isSafe(#"(a|aa){2}"#))
        #expect(!ReplacementSafety.isSafe(#"(a|aa){1,}"#))
        #expect(!ReplacementSafety.isSafe(#"(a|aa){0,}"#))
        #expect(!ReplacementSafety.isSafe(#"(a|aa){2,4}"#))
    }

    // Prefix-free literal branches are a prefix code, so the alternation is unambiguous and cannot
    // backtrack exponentially. These are ordinary patterns and must keep working.
    @Test func acceptsPrefixFreeLiteralAlternation() {
        #expect(ReplacementSafety.isSafe(#"(cat|dog)+"#))
        #expect(ReplacementSafety.isSafe(#"(red|blue)*"#))
        #expect(ReplacementSafety.isSafe(#"(cat|dog){2}"#))
        #expect(ReplacementSafety.isSafe(#"(cat|dog){2,4}"#))
        #expect(ReplacementSafety.isSafe(#"(?:cat|dog)+"#))
        #expect(ReplacementSafety.isSafe(#"(cat|dog)"#))         // unquantified: never analysed
        #expect(ReplacementSafety.isSafe(#"cat|dog"#))           // no group at all
    }

    // A `|` that is not a top-level alternation must not trigger the analysis at all.
    @Test func pipeInsideAClassOrEscapedIsNotAlternation() {
        #expect(ReplacementSafety.isSafe(#"([a|b])+"#))
        #expect(ReplacementSafety.isSafe(#"(a\|b)+"#))
        #expect(ReplacementSafety.isSafe(#"([|])+"#))
    }

    // Config files are hand-editable, so the editor's own length limit is not a bound the guard can rely
    // on. Fails closed: an over-long pattern is refused rather than scanned.
    @Test func overlongPatternsAreRefusedRatherThanScanned() {
        let huge = String(repeating: "(", count: 3_000) + "a" + String(repeating: ")", count: 3_000)
        #expect(huge.count > ReplacementSafety.maxPatternLength)
        #expect(!ReplacementSafety.isSafe(huge))
        #expect(ReplacementSafety.isSafe(String(repeating: "a", count: ReplacementSafety.maxPatternLength)))
    }

    @Test func unsafeRuleIsSkippedNotApplied() {
        let stage = ReplacementsStage(rules: [
            ReplacementRule(heard: #"(a+)+$"#, replace: "X", isRegex: true),
            ReplacementRule(heard: "hello", replace: "hi", isRegex: false),
        ])
        var ctx = PipelineContext(text: "aaaa hello")
        stage.apply(&ctx)
        #expect(ctx.text == "aaaa hi")
    }
}
