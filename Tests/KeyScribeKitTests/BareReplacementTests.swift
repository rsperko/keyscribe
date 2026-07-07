import Testing
@testable import KeyScribeKit

// A whole-utterance replacement is inserted verbatim and bare: when one replacement rule owns the
// entire utterance (modulo trailing whitespace/punctuation), the result is exactly that rule's
// generated output — no trailing space, no trailing punctuation, no LLM. Detected at the
// replacements stage and reported on the context (design discussion; design.md §4.2).
struct BareReplacementTests {
    private func detect(_ rules: [ReplacementRule], on text: String) -> String? {
        ReplacementsStage(rules: rules).bareReplacement(for: text)
    }

    @Test func wholeUtteranceLiteralClampsToGeneratedValue() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "slash replace") == "/replace")
    }

    // An engine that runs its own inverse-text-normalization emits the slashed form directly (Apple:
    // "slash resume" → "/Resume."). A literal rule keyed on that slashed form normalizes the casing —
    // the whole utterance clamps to the rule's generated value.
    @Test func wholeUtteranceLiteralNormalizesSlashedInput() {
        let rules = [ReplacementRule(heard: "/resume", replace: "/resume", isRegex: false)]
        #expect(detect(rules, on: "/Resume.") == "/resume")
        #expect(detect(rules, on: "  /RESUME  ") == "/resume")
    }

    // A stray STT period or surrounding whitespace must not defeat the clamp — that residue is
    // exactly the "trailing cruft" the predicate ignores.
    @Test func toleratesTrailingPunctuationAndSurroundingWhitespace() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "slash replace.") == "/replace")
        #expect(detect(rules, on: "  slash replace  ") == "/replace")
        #expect(detect(rules, on: "slash replace?") == "/replace")
    }

    // Leading residue ("send") means the rule did not own the whole utterance → no clamp.
    @Test func leadingResidueDoesNotClamp() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "send slash replace") == nil)
    }

    // Trailing residue ("now") is a word, not cruft → no clamp.
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

    // A literal fuzzy-style correction defined as a replacement clamps when said alone.
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

    // A mid-utterance pause ("Duct tape. Get") must not defeat a whole-utterance clamp.
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

    // The pause tolerance is still whole-utterance only: leading/trailing word residue does not clamp
    // even once the internal pause is bridged.
    @Test func internalPauseStillRequiresWholeUtteranceOwnership() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        #expect(detect(rules, on: "please duct tape. get") == nil)
        #expect(detect(rules, on: "duct tape. get me some") == nil)
    }

    // End-to-end through apply(): a paused whole-utterance command is reported as a bare replacement
    // on the context even though the inline transform left the punctuated text unchanged.
    @Test func applyReportsPausedWholeUtteranceReplacement() {
        let rules = [ReplacementRule(heard: #"duc[kt] tape get"#, replace: "dt get", isRegex: true)]
        var context = PipelineContext(text: "Duct tape. Get.")
        ReplacementsStage(rules: rules).apply(&context)
        #expect(context.bareReplacement == "dt get")
    }

    // Pause tolerance covers literal rules too, through the real apply() gate (a literal non-identity rule
    // makes the inline transform a no-op on paused input, exercising the gate's pause-mark clause).
    @Test func applyCoversLiteralPausedWholeUtteranceReplacement() {
        let rules = [ReplacementRule(heard: "duct tape get", replace: "dt get", isRegex: false)]
        func clamp(_ text: String) -> String? {
            var context = PipelineContext(text: text)
            ReplacementsStage(rules: rules).apply(&context)
            return context.bareReplacement
        }
        #expect(clamp("Duct tape get.") == "dt get")
        #expect(clamp("Duct tape. Get.") == "dt get")
        #expect(clamp("Duct tape, get") == "dt get")
        #expect(clamp("please duct tape. get") == nil)
    }

    // Whole-utterance only: a paused command embedded in a real sentence is not rewritten inline.
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

    // Robustness: if a second rule mutates the owner's generated output, the produced text no longer
    // equals the generated value, so we conservatively do NOT clamp (the normal path handles it).
    @Test func chainedMutationDoesNotClamp() {
        let rules = [
            ReplacementRule(heard: #"slash (\w+)"#, replace: "/$1", isRegex: true),
            ReplacementRule(heard: "dog", replace: "canine", isRegex: false),
        ]
        #expect(detect(rules, on: "slash dog") == nil)
    }

    // A LiveEdits control char (\n from "insert new line", \t from "insert tab") is a command's
    // OUTPUT, not STT cruft — clamping must not swallow it. The dictated control char is re-attached
    // around the clamped value, on whichever side it was dictated.
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

    // Pure punctuation/whitespace reduces to empty core → no clamp, no crash.
    @Test func emptyCoreNeverClamps() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        #expect(detect(rules, on: "  . ") == nil)
        #expect(detect(rules, on: "") == nil)
    }

    // apply() reports the clamp on the context; the normal text transform still happens for the
    // non-clamp path.
    @Test func applyReportsBareReplacementOnContext() {
        let rules = [ReplacementRule(heard: "slash replace", replace: "/replace", isRegex: false)]
        var clamp = PipelineContext(text: "slash replace")
        ReplacementsStage(rules: rules).apply(&clamp)
        #expect(clamp.bareReplacement == "/replace")

        var partial = PipelineContext(text: "send slash replace")
        ReplacementsStage(rules: rules).apply(&partial)
        #expect(partial.bareReplacement == nil)
        #expect(partial.text == "send /replace")
    }
}
