import Testing
@testable import KeyScribeKit

struct RuleExampleTests {
    private func rule(_ heard: String, _ replace: String, regex: Bool = true) -> ReplacementRule {
        ReplacementRule(heard: heard, replace: replace, isRegex: regex)
    }

    private func said(_ heard: String, _ replace: String = "x", regex: Bool = true) -> [String] {
        RuleExample.examples(for: rule(heard, replace, regex: regex)).map(\.said)
    }

    @Test func aLiteralRuleIsItsOwnPhrase() {
        #expect(RuleExample.examples(for: rule("slash resume", "/resume", regex: false))
                == [.init(said: "slash resume", result: "/resume")])
    }

    @Test func alternativesBecomeOnePhraseEach() {
        #expect(said(#"[\s,]*\b(?:my|insert)\s+sign[- ]?off[\s,.]*"#) == ["my sign off", "insert sign off"])
    }

    @Test func anOptionalGroupOffersTheLongerFormFirst() {
        #expect(said(#"\b(?:insert\s+)?shrug\s+emoji\b"#) == ["insert shrug emoji", "shrug emoji"])
        #expect(said(#"[\s,]*insert,?( a)? to[- ]?do[\s,.]*"#) == ["insert a to do", "insert to do"])
    }

    @Test func anOpenEndedCaptureIsAPlaceholderInPhraseAndResult() {
        let examples = RuleExample.examples(for: rule(#"(?i)^\s*go\s+to\s+(.+?)\s+manager[.!?]?\s*$"#, "run manager $1"))
        #expect(examples == [.init(said: "go to … manager", result: "run manager …")])
    }

    @Test func invisibleOutputIsNamed() {
        #expect(RuleExample.examples(for: rule(#"[\s,]*\b(?:my|insert)\s+sign[- ]?off[\s,.]*"#, #"\n\nBest,"#)).first?.result
                == "New paragraph + Best,")
        #expect(RuleExample.examples(for: rule(#"[\s,]*insert,?( a)? to[- ]?do[\s,.]*"#, #"\n// TODO: "#)).first?.result
                == "New line + // TODO:")
        #expect(RuleExample.examples(for: rule("insert indent", "\t", regex: false)).first?.result == "Tab")
        #expect(RuleExample.examples(for: rule("ship it", "ship it<CR>", regex: false)).first?.result == "ship it<CR>")
        #expect(RuleExample.examples(for: rule(#"send it"#, "done<CR>")).first?.result == "done, then presses Return")
    }

    @Test(arguments: [#"(?<=x)foo"#, #"\w+ thing"#, #"(a)\1"#, #"[a-z]+"#, #"foo.bar"#, #"(?=x)"#])
    func aPatternOutsideTheSubsetHasNoExample(_ pattern: String) {
        #expect(said(pattern).isEmpty)
    }

    @Test func anExampleTheRuleDoesNotMatchCompletelyIsDropped() {
        #expect(said(#"(?-i)Foo bar"#) == ["Foo bar"])
        #expect(said(#"a\bb"#).isEmpty)
        #expect(said(#"stop|stop it"#) == ["stop"])
    }

    @Test func everySeededPatternRuleThatHasExamplesMatchesThemCompletely() {
        for mode in ModeStore.starterModes() {
            for vocab in mode.replacements.rules where vocab.regex {
                let rule = ReplacementRule(heard: vocab.heard, replace: vocab.replace, isRegex: true)
                for example in RuleExample.examples(for: rule) where !example.said.contains("\u{2026}") {
                    #expect(RuleExample.matchesCompletely(rule, example.said), "\(mode.id): \(example.said)")
                }
            }
        }
    }

    @Test func theTaughtStarterPhrasesAreAmongTheExamples() {
        let all = ModeStore.starterModes().flatMap(\.replacements.rules).filter(\.regex)
            .flatMap { RuleExample.examples(for: ReplacementRule(heard: $0.heard, replace: $0.replace, isRegex: true)) }
            .map(\.said)
        for taught in ["insert sign off", "insert shrug emoji", "insert to do", "insert check box", "begin code block", "end bold"] {
            #expect(all.contains(taught), "\(taught)")
        }
    }
}

struct HelpAdvisoryTests {
    @Test(arguments: [("what can I say", false), ("Show commands", false), (#"^\s*what can i say[.?]?\s*$"#, true)])
    func aRuleForTheHelpPhraseSaysHelpWins(heard: String, regex: Bool) {
        #expect(ReplacementAuthoring.helpAdvisory(heard: heard, replace: "x", regex: regex)
                == "Saying \u{201C}\(VoiceCommandGrammar.help.first { heard.lowercased().contains($0.lowercased()) } ?? "what can I say")\u{201D} on its own shows what you can say instead.")
    }

    @Test(arguments: [("what can I say about it", false), ("slash resume", false), (#"what can i see"#, true)])
    func otherRulesHaveNoHelpAdvisory(heard: String, regex: Bool) {
        #expect(ReplacementAuthoring.helpAdvisory(heard: heard, replace: "x", regex: regex) == nil)
    }
}
