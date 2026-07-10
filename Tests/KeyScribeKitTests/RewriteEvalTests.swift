import Foundation
import Testing
@testable import KeyScribeKit

private func makeCase(
    id: String = "c1",
    tags: [String] = [],
    prompt: String = "Lightly clean up the dictated text.",
    transcript: String = "hello there",
    screenTerms: [String] = [],
    tokens: [String] = [],
    locale: String? = nil,
    fieldSingleLine: Bool? = nil,
    fieldPlainText: Bool? = nil,
    appName: String? = nil,
    precedingText: String? = nil,
    selectedText: String? = nil,
    userName: String? = nil,
    checks: RewriteEvalCase.Checks = .init()
) -> RewriteEvalCase {
    RewriteEvalCase(
        id: id, tags: tags, modePrompt: prompt, transcript: transcript,
        screenTerms: screenTerms, tokens: tokens, language: "English", locale: locale,
        fieldSingleLine: fieldSingleLine, fieldPlainText: fieldPlainText,
        appName: appName, precedingText: precedingText, selectedText: selectedText,
        userName: userName, checks: checks)
}

private func results(_ output: String, _ c: RewriteEvalCase) -> [RewriteEvalCheckResult] {
    RewriteEvalScoring.score(output: output, for: c)
}

private func verdict(_ kind: RewriteEvalCheckResult.Kind, in results: [RewriteEvalCheckResult]) -> Bool? {
    results.first { $0.kind == kind }?.passed
}

struct RewriteEvalManifestTests {
    @Test func decodesInlinePromptWithDefaults() throws {
        let json = """
        {"schemaVersion": 1, "cases": [
          {"id": "a", "prompt": "Clean up.", "transcript": "hi there",
           "checks": {"mustContain": ["hi"]}}
        ]}
        """
        let m = try RewriteEvalManifest.decode(Data(json.utf8))
        #expect(m.cases.count == 1)
        let c = try #require(m.cases.first)
        #expect(c.modePrompt == "Clean up.")
        #expect(c.tags.isEmpty)
        #expect(c.language == "English")
        #expect(c.screenTerms.isEmpty && c.tokens.isEmpty)
        #expect(c.checks.mustContain == ["hi"])
        #expect(c.checks.mustNotContain.isEmpty && c.checks.regexAbsent.isEmpty)
    }

    @Test func resolvesPromptId() throws {
        let json = """
        {"schemaVersion": 1,
         "prompts": {"polish": "Polish the text."},
         "cases": [{"id": "a", "promptId": "polish", "transcript": "hi", "checks": {}}]}
        """
        let m = try RewriteEvalManifest.decode(Data(json.utf8))
        #expect(m.cases.first?.modePrompt == "Polish the text.")
    }

    @Test func unknownPromptIdThrows() {
        let json = """
        {"schemaVersion": 1, "cases": [{"id": "a", "promptId": "nope", "transcript": "hi", "checks": {}}]}
        """
        #expect(throws: (any Error).self) { try RewriteEvalManifest.decode(Data(json.utf8)) }
    }

    @Test func duplicateCaseIdThrows() {
        let json = """
        {"schemaVersion": 1, "cases": [
          {"id": "a", "prompt": "p", "transcript": "hi", "checks": {}},
          {"id": "a", "prompt": "p", "transcript": "ho", "checks": {}}
        ]}
        """
        #expect(throws: (any Error).self) { try RewriteEvalManifest.decode(Data(json.utf8)) }
    }

    @Test func newerSchemaVersionThrows() {
        let json = """
        {"schemaVersion": 2, "cases": []}
        """
        #expect(throws: (any Error).self) { try RewriteEvalManifest.decode(Data(json.utf8)) }
    }
}

struct RewriteEvalScoringTests {
    @Test func whitespaceOutputFailsNonEmpty() {
        #expect(verdict(.nonEmpty, in: results("  \n ", makeCase())) == false)
    }

    @Test func preambleFailsNoPreamble() {
        #expect(verdict(.noPreamble, in: results("Here is the cleaned text: Hello there.", makeCase())) == false)
        #expect(verdict(.noPreamble, in: results("Sure! Hello there.", makeCase())) == false)
    }

    @Test func fencedOutputFailsNoPreamble() {
        #expect(verdict(.noPreamble, in: results("```\nHello there.\n```", makeCase())) == false)
    }

    @Test func fullyQuotedOutputFailsNoPreamble() {
        #expect(verdict(.noPreamble, in: results("\"Hello there.\"", makeCase())) == false)
    }

    @Test func cleanOutputPassesNoPreamble() {
        // "Here" as a sentence opener is legitimate prose — only preamble phrasing fails.
        #expect(verdict(.noPreamble, in: results("Here at the office, all is well.", makeCase())) == true)
    }

    @Test func mustContainIsCaseSensitive() {
        let c = makeCase(checks: .init(mustContain: ["ClaudeCode"]))
        #expect(verdict(.mustContain, in: results("I asked claudecode to fix it.", c)) == false)
        #expect(verdict(.mustContain, in: results("I asked ClaudeCode to fix it.", c)) == true)
    }

    @Test func mustNotContainIsCaseInsensitive() {
        let c = makeCase(checks: .init(mustNotContain: ["cloud code"]))
        #expect(verdict(.mustNotContain, in: results("I asked Cloud Code to fix it.", c)) == false)
        #expect(verdict(.mustNotContain, in: results("I asked ClaudeCode to fix it.", c)) == true)
    }

    @Test func regexAbsentFailsOnMatch() {
        let c = makeCase(checks: .init(regexAbsent: ["(?m)^#"]))
        #expect(verdict(.regexAbsent, in: results("# Heading\nbody", c)) == false)
        #expect(verdict(.regexAbsent, in: results("No heading here #tag", c)) == true)
    }

    @Test func missingTokenFailsTokens() {
        let c = makeCase(transcript: "call ⟦SN:ab12⟧ now", tokens: ["⟦SN:ab12⟧"])
        #expect(verdict(.tokens, in: results("call now", c)) == false)
        #expect(verdict(.tokens, in: results("call ⟦SN:ab12⟧ now", c)) == true)
    }

    @Test func tokenCheckAbsentWithoutTokens() {
        #expect(verdict(.tokens, in: results("hello", makeCase())) == nil)
    }

    @Test func contextEchoFailsWhenContextTrigramLeaks() {
        let c = makeCase(
            transcript: "send the update",
            precedingText: "Remember the deadline is Friday. Thanks!")
        #expect(verdict(.contextEcho, in: results("Send the update. The deadline is Friday.", c)) == false)
        #expect(verdict(.contextEcho, in: results("Send the update.", c)) == true)
    }

    @Test func contextEchoAllowsTrigramsAlsoInTranscript() {
        let c = makeCase(
            transcript: "the deadline is friday so send the update",
            precedingText: "Remember the deadline is Friday. Thanks!")
        #expect(verdict(.contextEcho, in: results("The deadline is Friday, so send the update.", c)) == true)
    }

    @Test func contextEchoCheckAbsentWithoutContext() {
        #expect(verdict(.contextEcho, in: results("hello", makeCase())) == nil)
    }

    @Test func maxWerBoundsRewriteDistance() {
        let c = makeCase(checks: .init(
            reference: "Send the update to the team today.", maxWer: 0.3))
        #expect(verdict(.maxWer, in: results("Send the update to the team today.", c)) == true)
        #expect(verdict(.maxWer, in: results("A completely different sentence about nothing at all.", c)) == false)
    }
}

struct RewriteEvalVariantsTests {
    @Test func variantIdsAreUnique() {
        let ids = RewriteEvalVariants.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("baseline"))
    }

    @Test func baselineFeedsNoTermsAndBaselineOptions() throws {
        let c = makeCase(transcript: "we use charge bee for billing",
                         screenTerms: ["ChargeBee"], userName: "Rick Sperko")
        let built = try #require(RewriteEvalVariants.build(c, variant: "baseline"))
        #expect(built.inputs.validTerms.isEmpty)
        #expect(built.inputs.fuzzyCandidates.isEmpty)
        #expect(built.options == .baseline)
        #expect(built.inputs.content == c.transcript)
        #expect(built.inputs.modePrompt == c.modePrompt)
    }

    @Test func screenTermsFeedExistingChannels() throws {
        let c = makeCase(transcript: "we use charge bee and OpenClaw daily",
                         screenTerms: ["ChargeBee", "OpenClaw", "Kubernetes"])
        let built = try #require(RewriteEvalVariants.build(c, variant: "screen-terms"))
        #expect(built.inputs.validTerms == ["OpenClaw"])
        #expect(built.inputs.fuzzyCandidates.contains(.init(heard: "charge bee", canonical: "ChargeBee")))
        #expect(built.options == .baseline)
    }

    @Test func userNameBecomesValidTerm() throws {
        let c = makeCase(userName: "Rick Sperko")
        let built = try #require(RewriteEvalVariants.build(c, variant: "user-name"))
        #expect(built.inputs.validTerms == ["Rick Sperko"])
    }

    @Test func optionVariantsSetOnlyTheirFlag() throws {
        let c = makeCase(locale: "en-US", fieldSingleLine: true, fieldPlainText: true)
        let reAnchor = try #require(RewriteEvalVariants.build(c, variant: "re-anchor"))
        #expect(reAnchor.options == PromptAssembler.Options(appendFinalReminder: true))
        let field = try #require(RewriteEvalVariants.build(c, variant: "field-hint"))
        #expect(field.options == PromptAssembler.Options(fieldAffordanceRule: true))
    }

    @Test func caseDateTimeReachesInputsInEveryVariant() throws {
        var c = makeCase()
        c = RewriteEvalCase(
            id: c.id, tags: c.tags, modePrompt: c.modePrompt, transcript: c.transcript,
            screenTerms: c.screenTerms, tokens: c.tokens, language: c.language, locale: c.locale,
            fieldSingleLine: c.fieldSingleLine, fieldPlainText: c.fieldPlainText,
            appName: c.appName, precedingText: c.precedingText, selectedText: c.selectedText,
            userName: c.userName, currentDateTime: "Friday, July 10, 2026, 9:00 AM", checks: c.checks)
        let baseline = try #require(RewriteEvalVariants.build(c, variant: "baseline"))
        #expect(baseline.inputs.currentDateTime == "Friday, July 10, 2026, 9:00 AM")
        #expect(baseline.options == .baseline)
    }

    @Test func unknownVariantReturnsNil() {
        #expect(RewriteEvalVariants.build(makeCase(), variant: "nope") == nil)
    }

    @Test func temperatureOverrideOnlyForTempZero() {
        #expect(RewriteEvalVariants.temperatureOverride(variant: "temp-0") == 0)
        #expect(RewriteEvalVariants.temperatureOverride(variant: "baseline") == nil)
    }
}
