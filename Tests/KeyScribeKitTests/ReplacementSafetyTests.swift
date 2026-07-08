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
