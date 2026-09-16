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

    @Test func trailingWordResidueDoesNotClamp() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "slash replace now") == nil)
    }

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

    @Test func regexClampIsCaseInsensitiveAgainstCapitalizedSTT() {
        let rules = [ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true)]
        #expect(detect(rules, on: "Slash dog.") == "/dog")
        #expect(detect(rules, on: "SLASH DOG") == "/DOG")
    }

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

    @Test func applyReportsPausedWholeUtteranceReplacement() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        var context = PipelineContext(text: "Duct tape. Get.")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement?.text == "dt get")
    }

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

    @Test func escapedCRIsLiteralTextNoReturn() {
        let rules = [ReplacementRule(heard: "slash resume", replace: #"/resume\<CR>"#, isRegex: true)]
        let bare = detectBare(rules, on: "slash resume")
        #expect(bare?.text == "/resume<CR>")
        #expect(bare?.submit == nil)
    }

    @Test func literalCRIsVerbatimNoReturn() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "/resume<CR>", isRegex: false)]
        let bare = detectBare(rules, on: "slash resume")
        #expect(bare?.text == "/resume<CR>")
        #expect(bare?.submit == nil)
    }

    @Test func nonTerminalCRDropsTheRule() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "foo<CR>bar", isRegex: true)]
        var context = PipelineContext(text: "slash resume")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement == nil)
        #expect(context.text == "slash resume")
    }

    @Test func crOnlyTemplateGeneratesEmptyText() {
        let rules = [ReplacementRule(heard: "slash resume", replace: "<CR>", isRegex: true)]
        #expect(detectBare(rules, on: "slash resume")?.text == "")
    }

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
