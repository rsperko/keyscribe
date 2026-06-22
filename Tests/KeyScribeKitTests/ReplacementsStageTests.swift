import Testing
@testable import KeyScribeKit

private func run(_ rules: [ReplacementRule], on text: String) -> String {
    var ctx = PipelineContext(text: text)
    ReplacementsStage(rules: rules).run(&ctx)
    return ctx.text
}

struct ReplacementsStageTests {
    @Test func literalReplacement() {
        #expect(run([ReplacementRule(heard: "teh", replace: "the", isRegex: false)], on: "teh cat") == "the cat")
    }

    @Test func literalIsCaseInsensitive() {
        #expect(run([ReplacementRule(heard: "teh", replace: "the", isRegex: false)], on: "Teh cat and teh dog")
            == "the cat and the dog")
    }

    @Test func literalMultiWordPhrase() {
        // Literal replacement consumes exactly the matched span; the preceding space stays.
        #expect(run([ReplacementRule(heard: " at gmail dot com", replace: "@gmail.com", isRegex: false)],
                    on: "email me at gmail dot com") == "email me@gmail.com")
    }

    @Test func regexWithCaptureGroup() {
        // template "\$$1" → literal $ followed by capture group 1
        #expect(run([ReplacementRule(heard: #"(\d+) dollars"#, replace: #"\$$1"#, isRegex: true)],
                    on: "that is 5 dollars") == "that is $5")
    }

    @Test func rulesApplyInOrder() {
        let rules = [
            ReplacementRule(heard: "cat", replace: "dog", isRegex: false),
            ReplacementRule(heard: "dog", replace: "fish", isRegex: false),
        ]
        // cat→dog then dog→fish ⇒ everything becomes fish
        #expect(run(rules, on: "cat") == "fish")
    }

    @Test func invalidRegexIsSkippedNotCrashing() {
        #expect(run([ReplacementRule(heard: "(unclosed", replace: "x", isRegex: true)], on: "(unclosed here")
            == "(unclosed here")
    }

    @Test func stageRunsAtReplacementsPositionAndOrder() {
        let stage = ReplacementsStage(rules: [])
        #expect(stage.position == .postSTTText)
        #expect(stage.order == StageOrder.replacements)
    }

    // An empty `heard` must be a no-op — replacingOccurrences(of: "") would otherwise splice the
    // replacement between every character.
    @Test func emptyHeardIsIgnored() {
        #expect(run([ReplacementRule(heard: "", replace: "X", isRegex: false)], on: "abc") == "abc")
    }
}
