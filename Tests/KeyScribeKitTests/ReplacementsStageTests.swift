import Testing
@testable import KeyScribeKit

private func run(_ rules: [ReplacementRule], on text: String) -> String {
    var ctx = PipelineContext(text: text)
    ReplacementsStage(rules: rules).apply(&ctx)
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

    // A literal rule matches whole words only — it must never fire inside a longer word.
    @Test func literalDoesNotMatchInsideWord() {
        let rule = ReplacementRule(heard: "pipe", replace: "|", isRegex: false)
        #expect(run([rule], on: "the pipeline is great") == "the pipeline is great")
        #expect(run([rule], on: "use a pipe here") == "use a | here")
    }

    // The whole-word constraint is case-insensitive at the boundary too.
    @Test func literalWholeWordIsCaseInsensitive() {
        #expect(run([ReplacementRule(heard: "pipe", replace: "|", isRegex: false)], on: "A Pipe and a PIPELINE")
            == "A | and a PIPELINE")
    }

    // A `\b` word boundary cannot anchor next to a non-word character, so a literal term whose edge is
    // punctuation (a slash-command "/resume", "c++") would never match with `\b` wrapped on that edge.
    // The boundary is applied only on word-character edges; a punctuation edge is left unwrapped.
    @Test func literalPunctuationLeadingEdgeMatchesCaseInsensitively() {
        let rule = ReplacementRule(heard: "/resume", replace: "/resume", isRegex: false)
        #expect(run([rule], on: "/Resume.") == "/resume.")
        #expect(run([rule], on: "please /Resume now") == "please /resume now")
    }

    // The word-character edge still enforces whole-word matching: "/resume" must not fire inside "/resumes".
    @Test func literalPunctuationLeadingEdgeStillGuardsWordEdge() {
        let rule = ReplacementRule(heard: "/resume", replace: "/RESUME", isRegex: false)
        #expect(run([rule], on: "the /resumes list") == "the /resumes list")
    }

    @Test func literalPunctuationTrailingEdgeMatches() {
        let rule = ReplacementRule(heard: "c++", replace: "cpp", isRegex: false)
        #expect(run([rule], on: "i love c++ a lot") == "i love cpp a lot")
    }

    // A literal replacement is inserted verbatim — $ / \\ in the replacement are not template refs.
    @Test func literalReplacementIsNotATemplate() {
        #expect(run([ReplacementRule(heard: "money", replace: "$5", isRegex: false)], on: "give me money")
            == "give me $5")
    }

    // Regex still controls its own boundaries — substring/partial matches are the user's call.
    @Test func regexCanMatchInsideWord() {
        #expect(run([ReplacementRule(heard: "pipe(.*)", replace: "X", isRegex: true)], on: "pipeline")
            == "X")
    }

    @Test func regexWithCaptureGroup() {
        // template "\$$1" → literal $ followed by capture group 1
        #expect(run([ReplacementRule(heard: #"(\d+) dollars"#, replace: #"\$$1"#, isRegex: true)],
                    on: "that is 5 dollars") == "that is $5")
    }

    // The match input is STT output, whose casing the engine chooses (it commonly capitalizes the
    // first word) — so regex rules match case-insensitively by default, like literal rules.
    @Test func regexIsCaseInsensitiveByDefault() {
        #expect(run([ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)], on: "Slash dog")
            == "/dog")
        #expect(run([ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)], on: "SLASH dog")
            == "/dog")
    }

    // (?-i) re-enables case sensitivity for the power user who genuinely needs it — the inline flag
    // must override the default case-insensitive option.
    @Test func regexCaseSensitivityOptOutWithInlineFlag() {
        let rule = ReplacementRule(heard: #"(?-i)slash (\w+)"#, replace: "/$1", isRegex: true)
        #expect(run([rule], on: "Slash dog") == "Slash dog")
        #expect(run([rule], on: "slash dog") == "/dog")
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
