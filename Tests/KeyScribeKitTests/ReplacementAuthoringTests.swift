import Testing
@testable import KeyScribeKit

struct ReplacementAuthoringTests {
    @Test func previewPassesShortSingleLineThrough() {
        #expect(ReplacementAuthoring.preview(for: "Hello").text == "Hello")
    }

    @Test func previewEscapesNewline() {
        #expect(ReplacementAuthoring.preview(for: "Hello\nworld").text == #"Hello\nworld"#)
        #expect(ReplacementAuthoring.preview(for: "\n").text == #"\n"#)
    }

    @Test func previewEscapesTabAndCarriageReturn() {
        #expect(ReplacementAuthoring.preview(for: "a\tb").text == #"a\tb"#)
        #expect(ReplacementAuthoring.preview(for: "a\rb").text == #"a\rb"#)
    }

    @Test func previewEscapesCRLFAsBothControls() {
        #expect(ReplacementAuthoring.preview(for: "a\r\nb").text == #"a\r\nb"#)
    }

    @Test func previewEmptyReadsNothing() {
        let preview = ReplacementAuthoring.preview(for: "")
        #expect(preview.text == "Nothing")
        #expect(preview.isTruncated == false)
        #expect(preview.fullCount == 0)
    }

    @Test func previewNeverExceedsLimitAndAnnouncesTruncation() {
        let body = String(repeating: "a", count: 500)
        let preview = ReplacementAuthoring.preview(for: body)
        #expect(preview.text.count == ReplacementAuthoring.previewLimit)
        #expect(preview.text.hasSuffix("…"))
        #expect(String(preview.text.dropLast()) == String(repeating: "a", count: ReplacementAuthoring.previewLimit - 1))
        #expect(preview.isTruncated)
        #expect(preview.fullCount == 500)
    }

    @Test func previewCapAppliesToEscapedLength() {
        let body = String(repeating: "\n", count: 100)
        let preview = ReplacementAuthoring.preview(for: body)
        #expect(preview.text.count == ReplacementAuthoring.previewLimit)
        #expect(preview.isTruncated)
        #expect(preview.fullCount == 100)
    }

    @Test func previewExactlyAtLimitIsNotTruncated() {
        let body = String(repeating: "a", count: ReplacementAuthoring.previewLimit)
        let preview = ReplacementAuthoring.preview(for: body)
        #expect(preview.text.count == ReplacementAuthoring.previewLimit)
        #expect(preview.isTruncated == false)
    }

    @Test func limitConstantMatchesDesign() {
        #expect(ReplacementAuthoring.maxCharacters == 65_536)
        #expect(ReplacementAuthoring.previewLimit == 160)
    }

    @Test func exactlyAtLimitIsWithinLimit() {
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "a", count: 65_536)))
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "a", count: 65_537)) == false)
    }

    @Test func limitCountsUserPerceivedCharacters() {
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "🇺🇸", count: 65_536)))
        #expect(ReplacementAuthoring.isWithinLimit(String(repeating: "🇺🇸", count: 65_537)) == false)
    }

    @Test func regexReturnMarkerValidWhenTerminalOrAbsent() {
        #expect(ReplacementAuthoring.regexReturnMarkerValid("/resume<CR>"))
        #expect(ReplacementAuthoring.regexReturnMarkerValid("just text"))
        #expect(ReplacementAuthoring.regexReturnMarkerValid(#"a\<CR>b"#))
    }

    @Test func regexReturnMarkerInvalidWhenNonTerminal() {
        #expect(ReplacementAuthoring.regexReturnMarkerValid("mid<CR>text") == false)
    }

    @Test func onlyALiteralRuleTypesItsReturnMarkerAsText() {
        #expect(ReplacementAuthoring.literalReturnMarkerAdvisory(replace: "/resume<CR>", regex: false) != nil)
        #expect(ReplacementAuthoring.literalReturnMarkerAdvisory(replace: "/resume<CR>", regex: true) == nil)
        #expect(ReplacementAuthoring.literalReturnMarkerAdvisory(replace: "/resume", regex: false) == nil)
    }

    @Test func lineEndingsNormalizeToLF() {
        #expect(ReplacementAuthoring.normalizingLineEndings("a\r\nb") == "a\nb")
        #expect(ReplacementAuthoring.normalizingLineEndings("a\rb") == "a\nb")
        #expect(ReplacementAuthoring.normalizingLineEndings("a\nb") == "a\nb")
        #expect(ReplacementAuthoring.normalizingLineEndings("a\r\nb\rc\nd") == "a\nb\nc\nd")
    }

    @Test func crlfOnlyStringStillNormalizes() {
        #expect(ReplacementAuthoring.normalizingLineEndings("\r\n") == "\n")
        #expect(ReplacementAuthoring.normalizingLineEndings("line one\r\nline two") == "line one\nline two")
    }

    @Test func previewMakesWhitespaceOnlySpacesVisible() {
        #expect(ReplacementAuthoring.preview(for: "  ").text == "␣␣")
        #expect(ReplacementAuthoring.preview(for: " \t ").text == #"␣\t␣"#)
    }

    @Test func previewLeavesSpacesAlongsideContentAlone() {
        #expect(ReplacementAuthoring.preview(for: " a ").text == " a ")
    }

    @Test func onlyTheRetiredSeededSignOffIsFlaggedForItsPlaceholder() {
        let old = ReplacementAuthoring.retiredSignOffRule
        #expect(ReplacementAuthoring.placeholderAdvisory(heard: old.heard, replace: old.replace, regex: true) != nil)
        #expect(ReplacementAuthoring.placeholderAdvisory(heard: old.heard, replace: #"\n\nBest,\nRick"#, regex: true) == nil)
        #expect(ReplacementAuthoring.placeholderAdvisory(heard: "sign off", replace: old.replace, regex: false) == nil)
        #expect(ReplacementAuthoring.placeholderAdvisory(heard: old.heard, replace: old.replace, regex: false) == nil)
        let seeded = ModeStore.starterModes().first { $0.id == "email" }?.replacements.rules ?? []
        #expect(!seeded.isEmpty)
        #expect(seeded.allSatisfy {
            ReplacementAuthoring.placeholderAdvisory(heard: $0.heard, replace: $0.replace, regex: $0.regex) == nil
        })
    }

    private func runRegex(_ pattern: String, _ replace: String, _ text: String) -> PipelineContext {
        var ctx = PipelineContext(text: text)
        ReplacementsStage(rules: [ReplacementRule(heard: pattern, replace: replace, isRegex: true)]).apply(&ctx)
        return ctx
    }

    @Test func matchingWholeWordsStopsMatchesInsideWordsAndKeepsTheRest() throws {
        let wrapped = try #require(ReplacementAuthoring.wholeWordPattern("p[iy]e?"))
        let ctx = runRegex(wrapped, "pi<CR>", "I copy the pieces and pi")
        #expect(ctx.text == "I copy the pieces and pi")
        #expect(ctx.replacementEffects.map(\.insideWord) == [false])
        #expect(runRegex(wrapped, "pi<CR>", "pie").bareReplacement == BareReplacement(text: "pi", submit: .return))
        #expect(runRegex(try #require(ReplacementAuthoring.wholeWordPattern("sean")), "Shawn", "Seanna and sean").text
            == "Seanna and Shawn")
    }

    @Test func matchingWholeWordsKeepsAPatternThatStartsOrEndsOnPunctuation() throws {
        let wrapped = try #require(ReplacementAuthoring.wholeWordPattern(#"[\s,]*my sign[- ]?off[\s,.]*"#))
        #expect(runRegex(wrapped, #"\n\nBest,"#, "talk soon, my sign off").text == "talk soon\n\nBest,")
    }

    @Test func matchingWholeWordsKeepsAlternativesAndCaptures() throws {
        let wrapped = try #require(ReplacementAuthoring.wholeWordPattern("(cat|dog)s?"))
        #expect(runRegex(wrapped, "[$1]", "cats and hotdogs and a dog").text == "[cat] and hotdogs and a [dog]")
    }

    @Test func matchingWholeWordsIsNotOfferedWhereWrappingCouldChangeTheMeaning() {
        #expect(ReplacementAuthoring.wholeWordPattern("(?x) pi  # comment") == nil)
        #expect(ReplacementAuthoring.wholeWordPattern("(?ix)pi") == nil)
        #expect(ReplacementAuthoring.wholeWordPattern("(?<=a)pi") == nil)
        #expect(ReplacementAuthoring.wholeWordPattern("pi(?=e)") == nil)
        #expect(ReplacementAuthoring.wholeWordPattern("pi(") == nil)
    }

    @Test func aReturnPressingRuleThatCanActMidSentenceSaysItsReturnIsDropped() {
        #expect(ReplacementAuthoring.returnScopeAdvisory(replace: "pi<CR>", regex: true, wholeDictation: false) != nil)
        #expect(ReplacementAuthoring.returnScopeAdvisory(replace: "pi<CR>", regex: true, wholeDictation: true) == nil)
        #expect(ReplacementAuthoring.returnScopeAdvisory(replace: "pi<CR>", regex: false, wholeDictation: false) == nil)
        #expect(ReplacementAuthoring.returnScopeAdvisory(replace: #"pi\<CR>"#, regex: true, wholeDictation: false) == nil)
    }

    @Test func aRuleSaysWhatItDoesInOneSentenceOnlyWhenThatIsNotObvious() {
        #expect(ReplacementAuthoring.behaviorSummary(replace: "/resume<CR>", regex: true, wholeDictation: true)
            == "Matches only when said alone. Presses Return.")
        #expect(ReplacementAuthoring.behaviorSummary(replace: "/resume", regex: false, wholeDictation: true)
            == "Matches only when said alone.")
        #expect(ReplacementAuthoring.behaviorSummary(replace: "Kryten", regex: false, wholeDictation: false) == nil)
        #expect(ReplacementAuthoring.behaviorSummary(replace: "pi<CR>", regex: true, wholeDictation: false) == nil)
    }

    @Test func theDroppedReturnWarningSaysWhatTheRuleDoesInSentences() {
        #expect(ReplacementAuthoring.returnScopeAdvisory(replace: "pi<CR>", regex: true, wholeDictation: false)
            == "This rule also replaces words within sentences, where Return is skipped.")
    }
}
