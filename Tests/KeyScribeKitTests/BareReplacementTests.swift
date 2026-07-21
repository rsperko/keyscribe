import Testing
@testable import KeyScribeKit

// A whole-utterance replacement is inserted verbatim and bare: when one replacement rule owns the
// entire utterance (modulo trailing whitespace/punctuation), the result is exactly that rule's
// generated output — no trailing space, no trailing punctuation, no LLM (design.md §4.2).
struct BareReplacementTests {
    private func detect(_ rules: [ReplacementRule], on text: String) -> String? {
        ReplacementsStage(rules: rules).bareReplacement(for: text)?.text
    }

    private func detectBare(_ rules: [ReplacementRule], on text: String) -> BareReplacement? {
        ReplacementsStage(rules: rules).bareReplacement(for: text)
    }

    @Test func wholeUtteranceLiteralClampsToGeneratedValue() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "slash replace") == "/replace")
    }

    // An engine with its own inverse-text-normalization emits the slashed form directly (Apple:
    // "slash resume" → "/Resume."); a literal rule keyed on that form still clamps, normalizing casing.
    @Test func wholeUtteranceLiteralNormalizesSlashedInput() {
        let rules = [ReplacementRule(heard: "/resume", replace: "/resume", isRegex: false)]
        #expect(detect(rules, on: "/Resume.") == "/resume")
        #expect(detect(rules, on: "  /RESUME  ") == "/resume")
    }

    @Test func toleratesTrailingPunctuationAndSurroundingWhitespace() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "slash replace.") == "/replace")
        #expect(detect(rules, on: "  slash replace  ") == "/replace")
        #expect(detect(rules, on: "slash replace?") == "/replace")
    }

    @Test func leadingResidueDoesNotClamp() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "send slash replace") == nil)
    }

    // Unlike trailing punctuation, a trailing word is not cruft, so it still blocks the clamp.
    @Test func trailingWordResidueDoesNotClamp() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "slash replace now") == nil)
    }

    // Regex rule: the clamped value is the SUBSTITUTED output ("/dog"), never the template ("/$1").
    @Test func regexClampsToSubstitutedOutput() {
        let rules = [ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)]
        #expect(detect(rules, on: "slash dog") == "/dog")
        #expect(detect(rules, on: "slash dog.") == "/dog")
        #expect(detect(rules, on: "send slash dog") == nil)
    }

    @Test func literalCorrectionWholeUtterance() {
        let rules = [ReplacementRule(heard: "Melborn", replace: "Melbourne", isRegex: false)]
        #expect(detect(rules, on: "Melborn") == "Melbourne")
        #expect(detect(rules, on: "going to Melborn") == nil)
    }

    // Regex matches case-insensitively, so a capitalized STT utterance still clamps. The capture
    // preserves the matched word's case ($1), so only matching is case-folded, not the output.
    @Test func regexClampIsCaseInsensitiveAgainstCapitalizedSTT() {
        let rules = [ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)]
        #expect(detect(rules, on: "Slash dog.") == "/dog")
        #expect(detect(rules, on: "SLASH DOG") == "/DOG")
    }

    // (?-i) opts back into case sensitivity even at the clamp level.
    @Test func regexClampRespectsCaseSensitivityOptOut() {
        let rules = [ReplacementRule(heard: #"(?-i)slash (\w+)"#, replace: "/$1", isRegex: true)]
        #expect(detect(rules, on: "Slash dog.") == nil)
        #expect(detect(rules, on: "slash dog") == "/dog")
    }

    @Test func internalPauseDoesNotDefeatWholeUtteranceClamp() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        #expect(detect(rules, on: "Duck tape get.") == "dt get")
        #expect(detect(rules, on: "Duct tape. Get.") == "dt get")
        #expect(detect(rules, on: "Duct tape, get") == "dt get")
        #expect(detect(rules, on: "Duct. Tape. Get.") == "dt get")
    }

    // Every boundary mark is handled the same whether internal or trailing; dash is not a pause mark.
    @Test func allSentencePunctuationBridgesOrTrims() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        for boundary in [".", ",", "!", "?", ";", ":"] {
            #expect(detect(rules, on: "Duct tape\(boundary) get") == "dt get")   // internal pause
            #expect(detect(rules, on: "Duct tape get\(boundary)") == "dt get")   // trailing residue
        }
        #expect(detect(rules, on: "Duct tape - get") == nil)                     // dash: not a pause mark
    }

    @Test func internalPauseStillRequiresWholeUtteranceOwnership() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        #expect(detect(rules, on: "please duct tape. get") == nil)
        #expect(detect(rules, on: "duct tape. get me some") == nil)
    }

    // Exercises the real apply() path (not the bareReplacement() helper): the inline transform leaves
    // the punctuated text unchanged, but the clamp is still reported on the context.
    @Test func applyReportsPausedWholeUtteranceReplacement() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        var context = PipelineContext(text: "Duct tape. Get.")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement?.text == "dt get")
    }

    // Literal (non-regex) rules get the same pause tolerance, exercised through apply()'s pause-mark clause.
    @Test func applyCoversLiteralPausedWholeUtteranceReplacement() {
        let rules = [ReplacementRule(heard: "duct tape get", replace: "dt get", isRegex: false)]
        func clamp(_ text: String) -> String? {
            var context = PipelineContext(text: text)
            ReplacementsStage(rules: rules).apply(&context)
            return context.bareReplacement?.text
        }
        #expect(clamp("Duct tape get.") == "dt get")
        #expect(clamp("Duct tape. Get.") == "dt get")
        #expect(clamp("Duct tape, get") == "dt get")
        #expect(clamp("please duct tape. get") == nil)
    }

    @Test func inlineTransformStaysExactAcrossAPause() {
        let rules = [ReplacementRule(heard: "duct tape get", replace: "dt get", isRegex: false)]
        var context = PipelineContext(text: "I use duct tape. Get some coffee.")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement == nil)
        #expect(context.text == "I use duct tape. Get some coffee.")
    }

    @Test func noRulesNeverClamp() {
        #expect(detect([], on: "hello") == nil)
        #expect(detect([ReplacementRule(heard: "x", replace: "y", isRegex: false)], on: "hello") == nil)
    }

    @Test func replacementOutputIsNotReprocessedWhenClamping() {
        let rules = [
            ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true),
            ReplacementRule(heard: "dog", replace: "canine", isRegex: false),
        ]
        #expect(detect(rules, on: "slash dog") == "/dog")
    }

    // A LiveEdits control char (\n from "insert new line", \t from "insert tab") is the command's
    // OUTPUT, not STT cruft to trim — clamping re-attaches it around the clamped value.
    @Test func preservesDictatedTrailingNewline() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false)]
        #expect(detect(rules, on: "slash resume\n") == "/resume\n")
    }

    @Test func preservesDictatedLeadingNewline() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false)]
        #expect(detect(rules, on: "\nslash resume") == "\n/resume")
    }

    @Test func preservesDictatedTabAlongsideTrimmedSpace() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume", isRegex: false)]
        #expect(detect(rules, on: "slash resume \t") == "/resume\t")
    }

    @Test func wholeUtteranceRegexEscapeExpandsInClamp() {
        let rules = [ReplacementRule(heard: "insert code fence", replace: #"```\n"#, isRegex: true)]
        #expect(detect(rules, on: "insert code fence") == "```\n")
        #expect(detect(rules, on: "Insert code fence.") == "```\n")
    }

    @Test func emptyCoreNeverClamps() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "  . ") == nil)
        #expect(detect(rules, on: "") == nil)
    }

    @Test func applyReportsBareReplacementOnContext() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        var clamp = PipelineContext(text: "slash replace")
        ReplacementsStage(rules: rules).apply(&clamp)
        #expect(clamp.bareReplacement?.text == "/replace")

        var partial = PipelineContext(text: "send slash replace")
        ReplacementsStage(rules: rules).apply(&partial)
        #expect(partial.bareReplacement == nil)
        #expect(partial.text == "send /replace")
    }

    // A terminal <CR> is stripped from the inserted text and instead requests a Return submit
    // (agent_notes/replace_with_return).
    @Test func regexCRSuffixRequestsReturn() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume<CR>", isRegex: true)]
        let bare = detectBare(rules, on: "slash resume")
        #expect(bare?.text == "/resume")
        #expect(bare?.submit == .return)
    }

    @Test func regexCRSuffixToleratesTrailingResidue() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume<CR>", isRegex: true)]
        #expect(detectBare(rules, on: "slash resume.")?.text == "/resume")
        #expect(detectBare(rules, on: "  slash resume  ")?.submit == .return)
    }

    @Test func crSuffixDoesNotFireInProse() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume<CR>", isRegex: true)]
        var context = PipelineContext(text: "please run slash resume")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement == nil)
        #expect(context.text == "please run /resume")
    }

    @Test func regexCRSuffixWithCaptureExpansion() {
        let rules = [ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1<CR>", isRegex: true)]
        let bare = detectBare(rules, on: "slash foo")
        #expect(bare?.text == "/foo")
        #expect(bare?.submit == .return)
    }

    // `\<CR>` is the escape: literal <CR> text, no Return.
    @Test func escapedCRIsLiteralTextNoReturn() {
        let rules = [ReplacementRule(heard: "slash resume", replace: #"/resume\<CR>"#, isRegex: true)]
        let bare = detectBare(rules, on: "slash resume")
        #expect(bare?.text == "/resume<CR>")
        #expect(bare?.submit == nil)
    }

    // A literal rule is never interpreted: <CR> is inserted verbatim, no Return.
    @Test func literalCRIsVerbatimNoReturn() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume<CR>", isRegex: false)]
        let bare = detectBare(rules, on: "slash resume")
        #expect(bare?.text == "/resume<CR>")
        #expect(bare?.submit == nil)
    }

    // A non-terminal <CR> is invalid config → the regex rule is dropped, so nothing matches.
    @Test func nonTerminalCRDropsTheRule() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "foo<CR>bar", isRegex: true)]
        var context = PipelineContext(text: "slash resume")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement == nil)
        #expect(context.text == "slash resume")
    }

    // A <CR>-only template owns the utterance but generates empty text. The controller routes empty text
    // to .noSpeech and fires the Return only on a verified .inserted, so no key is pressed (app-target
    // test crOnlyOutputIsNoSpeechNoSubmit proves the guarantee end-to-end).
    @Test func crOnlyTemplateGeneratesEmptyText() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "<CR>", isRegex: true)]
        #expect(detectBare(rules, on: "slash resume")?.text == "")
    }

    // Only the template suffix can request Return: a captured group whose runtime text happens to be
    // "<CR>" does not (provenance is template-authored, not runtime).
    @Test func runtimeCRInCaptureDoesNotRequestReturn() {
        let rules = [ReplacementRule(heard: #"say (.+)"#, replace: "/$1", isRegex: true)]
        let bare = detectBare(rules, on: "say <CR>")
        #expect(bare?.text == "/<CR>")
        #expect(bare?.submit == nil)
    }

    @Test func laterRuleDoesNotChangeBareReplacementOrSubmit() {
        let rules = [
            ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1<CR>", isRegex: true),
            ReplacementRule(heard: "dog", replace: "canine", isRegex: false),
        ]
        #expect(detectBare(rules, on: "slash dog") == BareReplacement(text: "/dog", submit: .return))
    }
}
