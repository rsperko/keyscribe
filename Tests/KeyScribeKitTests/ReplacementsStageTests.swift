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

    @Test func literalDoesNotMatchInsideWord() {
        let rule = ReplacementRule(heard: "pipe", replace: "|", isRegex: false)
        #expect(run([rule], on: "the pipeline is great") == "the pipeline is great")
        #expect(run([rule], on: "use a pipe here") == "use a | here")
    }

    @Test func literalWholeWordIsCaseInsensitive() {
        #expect(run([ReplacementRule(heard: "pipe", replace: "|", isRegex: false)], on: "A Pipe and a PIPELINE")
            == "A | and a PIPELINE")
    }

    // `\b` cannot anchor next to a non-word character, so a term whose edge is punctuation ("/resume",
    // "c++") would never match with `\b` wrapped on that edge — the boundary is applied only on
    // word-character edges, punctuation edges are left unwrapped.
    @Test func literalPunctuationLeadingEdgeMatchesCaseInsensitively() {
        let rule = ReplacementRule(heard: "/resume", replace: "/resume", isRegex: false)
        #expect(run([rule], on: "/Resume.") == "/resume.")
        #expect(run([rule], on: "please /Resume now") == "please /resume now")
    }

    // The word-character edge still enforces whole-word matching even with punctuation on the other edge.
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

    // Unlike literal rules, regex controls its own boundaries — substring/partial matches are the user's call.
    @Test func regexCanMatchInsideWord() {
        #expect(run([ReplacementRule(heard: "pipe(.*)", replace: "X", isRegex: true)], on: "pipeline")
            == "X")
    }

    @Test func regexWithCaptureGroup() {
        // `\$$1` → literal $ followed by capture group 1
        #expect(run([ReplacementRule(heard: #"(\d+) dollars"#, replace: #"\$$1"#, isRegex: true)],
                    on: "that is 5 dollars") == "that is $5")
    }

    // STT output's casing is engine-chosen (it commonly capitalizes the first word), so regex rules
    // match case-insensitively by default, like literal rules.
    @Test func regexIsCaseInsensitiveByDefault() {
        #expect(run([ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)], on: "Slash dog")
            == "/dog")
        #expect(run([ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)], on: "SLASH dog")
            == "/dog")
    }

    // The inline `(?-i)` flag must override the default case-insensitive option.
    @Test func regexCaseSensitivityOptOutWithInlineFlag() {
        let rule = ReplacementRule(heard: #"(?-i)slash (\w+)"#, replace: "/$1", isRegex: true)
        #expect(run([rule], on: "Slash dog") == "Slash dog")
        #expect(run([rule], on: "slash dog") == "/dog")
    }

    @Test func regexReplacementInterpretsEscapes() {
        #expect(run([ReplacementRule(heard: "insert code fence", replace: #"```\n"#, isRegex: true)],
                    on: "insert code fence") == "```\n")
        #expect(run([ReplacementRule(heard: "tab here", replace: #"\t"#, isRegex: true)], on: "tab here")
            == "\t")
    }

    // `\\n` is the escape hatch for a literal backslash followed by n.
    @Test func regexEscapedBackslashStaysLiteral() {
        #expect(run([ReplacementRule(heard: "back", replace: #"\\n"#, isRegex: true)], on: "back") == #"\n"#)
    }

    @Test func literalReplacementDoesNotInterpretEscapes() {
        #expect(run([ReplacementRule(heard: "fence", replace: #"```\n"#, isRegex: false)], on: "fence")
            == #"```\n"#)
    }

    @Test func replacementOutputIsNotReprocessed() {
        let rules = [
            ReplacementRule(heard: "cat", replace: "dog", isRegex: false),
            ReplacementRule(heard: "dog", replace: "fish", isRegex: false),
        ]
        #expect(run(rules, on: "cat") == "dog")
        #expect(run(rules, on: "dog") == "fish")
    }

    @Test func longestMatchWins() {
        let rules = [
            ReplacementRule(heard: "code fence", replace: "GLOBAL", isRegex: false),
            ReplacementRule(heard: "insert code fence", replace: "MODE", isRegex: false),
        ]
        #expect(run(rules, on: "insert code fence") == "MODE")
        #expect(run(rules, on: "code fence") == "GLOBAL")
    }

    @Test func modeRuleWinsEqualLengthTie() {
        let global = [ReplacementRule(heard: #"code\s+fence"#, replace: "GLOBAL", isRegex: true)]
        let local = [ReplacementRule(heard: "code fence", replace: "MODE", isRegex: false)]
        let rules = VocabularyMerge.rules(global: global, local: local, includeGlobal: true)
        #expect(run(rules, on: "code fence") == "MODE")
    }

    @Test func longerModeRuleWinsOverGlobalSubstring() {
        let global = [ReplacementRule(
            heard: #"\s*code fence[\s.,]*"#, replace: "GLOBAL", isRegex: true)]
        let local = [ReplacementRule(
            heard: #"\s*insert code fence[\s.,]*"#, replace: "MODE", isRegex: true)]
        let rules = VocabularyMerge.rules(global: global, local: local, includeGlobal: true)
        #expect(run(rules, on: "insert code fence") == "MODE")
    }

    @Test func firstRuleWinsEqualLengthTie() {
        let rules = [
            ReplacementRule(heard: #"code\s+fence"#, replace: "FIRST", isRegex: true),
            ReplacementRule(heard: "code fence", replace: "SECOND", isRegex: false),
        ]
        #expect(run(rules, on: "code fence") == "FIRST")
    }

    @Test func anchorsUseTheRunBounds() {
        let rules = [
            ReplacementRule(heard: #"^code"#, replace: "START", isRegex: true),
            ReplacementRule(heard: #"fence$"#, replace: "END", isRegex: true),
        ]
        #expect(run(rules, on: "code then fence") == "START then END")
        #expect(run(rules, on: "not code then fence later") == "not code then fence later")
    }

    @Test func scannerPreservesUnicodeCharacters() {
        let rules = [ReplacementRule(heard: "code fence", replace: "```", isRegex: false)]
        #expect(run(rules, on: "🧑🏽‍💻 code fence café") == "🧑🏽‍💻 ``` café")
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

    @Test func zeroLengthRegexIsIgnored() {
        #expect(run([ReplacementRule(heard: #"(?=abc)"#, replace: "X", isRegex: true)], on: "abc") == "abc")
    }

    // A regex rule with a mid-template (non-terminal) <CR> is invalid config: it is dropped from matching
    // AND surfaced on droppedForReturnMarker so the host can log the vanished rule.
    @Test func nonTerminalReturnMarkerRuleIsDroppedAndSurfaced() {
        let bad = ReplacementRule(heard: "go", replace: "a<CR>b", isRegex: true)
        let stage = ReplacementsStage(rules: [bad])
        var ctx = PipelineContext(text: "go now")
        stage.apply(&ctx)
        #expect(ctx.text == "go now")
        #expect(stage.droppedForReturnMarker == [bad])
    }

    // <CR> presses Return, so a terminal one is valid and applies without being reported as dropped.
    @Test func terminalReturnMarkerRuleIsNotReportedAsDropped() {
        let stage = ReplacementsStage(rules: [ReplacementRule(heard: "go", replace: "x<CR>", isRegex: true)])
        #expect(stage.droppedForReturnMarker.isEmpty)
    }
}
