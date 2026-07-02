import Testing
@testable import KeyScribeKit

struct OutputCleanupTests {
    @Test func trimsTrailingPeriod() {
        #expect(OutputCleanup.trimTrailingPunctuation("ls -la.") == "ls -la")
    }

    @Test func trimsTrailingQuestionMark() {
        #expect(OutputCleanup.trimTrailingPunctuation("how do I list files?") == "how do I list files")
    }

    @Test func trimsRunOfTerminators() {
        #expect(OutputCleanup.trimTrailingPunctuation("Really?!") == "Really")
        #expect(OutputCleanup.trimTrailingPunctuation("Wait...") == "Wait")
    }

    @Test func trimsTrailingWhitespaceAroundTerminators() {
        #expect(OutputCleanup.trimTrailingPunctuation("done . ") == "done")
        #expect(OutputCleanup.trimTrailingPunctuation("ls -la \n") == "ls -la")
    }

    @Test func leavesClosingQuoteUntouched() {
        #expect(OutputCleanup.trimTrailingPunctuation(#"echo "hi.""#) == #"echo "hi.""#)
    }

    @Test func leavesClosingParenUntouched() {
        #expect(OutputCleanup.trimTrailingPunctuation("printf (x)") == "printf (x)")
    }

    @Test func leavesCodeFenceUntouched() {
        #expect(OutputCleanup.trimTrailingPunctuation("```\ncode\n```") == "```\ncode\n```")
    }

    @Test func doesNotTrimTrailingComma() {
        #expect(OutputCleanup.trimTrailingPunctuation("Thanks,") == "Thanks,")
    }

    @Test func leavesInteriorPunctuationAlone() {
        #expect(OutputCleanup.trimTrailingPunctuation("git commit -m \"fix.\" --amend") == "git commit -m \"fix.\" --amend")
    }

    @Test func trimsEllipsisGlyph() {
        #expect(OutputCleanup.trimTrailingPunctuation("hold on\u{2026}") == "hold on")
    }

    @Test func returnsEmptyForAllPunctuation() {
        #expect(OutputCleanup.trimTrailingPunctuation("?!.") == "")
    }

    @Test func leavesCleanStringUnchanged() {
        #expect(OutputCleanup.trimTrailingPunctuation("git status") == "git status")
    }

    @Test func handlesEmptyString() {
        #expect(OutputCleanup.trimTrailingPunctuation("") == "")
    }

    @Test func blanksBlankAudioMarker() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("[BLANK_AUDIO]") == "")
    }

    @Test func blanksBlankAudioDisplayCasing() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("[Blank audio]") == "")
    }

    @Test func blanksParentheticalSoundTags() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("(water running)") == "")
        #expect(OutputCleanup.blankingNonSpeechAnnotation("[Music]") == "")
    }

    @Test func blanksRepeatedMarkers() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("[BLANK_AUDIO] [BLANK_AUDIO]") == "")
    }

    @Test func blanksMarkerWithSurroundingWhitespace() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("  [BLANK_AUDIO]  ") == "")
    }

    @Test func blanksMarkerWithStrayPunctuation() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("[BLANK_AUDIO].") == "")
    }

    @Test func keepsRealTextContainingParenthetical() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("(laughs) that was funny") == "(laughs) that was funny")
    }

    @Test func keepsRealTextContainingBrackets() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("the array[0] value") == "the array[0] value")
    }

    @Test func keepsLexicalHallucinationForVADLayer() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("Thank you.") == "Thank you.")
        #expect(OutputCleanup.blankingNonSpeechAnnotation("No") == "No")
        #expect(OutputCleanup.blankingNonSpeechAnnotation("\u{55EF}\u{3002}") == "\u{55EF}\u{3002}")
    }

    @Test func keepsBarePunctuationUntouched() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("...") == "...")
    }

    @Test func keepsNormalTranscript() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("open the pod bay doors") == "open the pod bay doors")
    }

    @Test func annotationBlankingHandlesEmptyString() {
        #expect(OutputCleanup.blankingNonSpeechAnnotation("") == "")
    }

    @Test func stripsTrailingEndMarker() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("real dictated text [END]") == "real dictated text")
    }

    @Test func stripsLeadingEndMarker() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("[END] real dictated text") == "real dictated text")
    }

    @Test func stripsTrailingBlankAudioOnRealSpeech() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("hello there [BLANK_AUDIO]") == "hello there")
    }

    @Test func stripsRepeatedLeadingMarkers() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("[END] [END] hello") == "hello")
    }

    @Test func stripsMarkersOnBothEdges() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("[Music] the pod bay doors [END]") == "the pod bay doors")
    }

    @Test func keepsInteriorBracketToken() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("the array[0] value") == "the array[0] value")
    }

    @Test func keepsAnchoredBracketWithDigit() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("run task [2]") == "run task [2]")
    }

    @Test func keepsAnchoredBracketWithOperator() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("set the value [i=1]") == "set the value [i=1]")
    }

    @Test func keepsUnbracketedTranscript() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("open the pod bay doors") == "open the pod bay doors")
    }

    @Test func boundaryAnnotationHandlesEmptyString() {
        #expect(OutputCleanup.strippingBoundaryAnnotation("") == "")
    }

    @Test func boundaryLayoutRestoresOriginalNewlinesAndTabs() {
        #expect(OutputCleanup.preserveBoundaryLayout(from: "\n\tHello\n\n", in: "Hello.") == "\n\tHello.\n\n")
    }

    @Test func boundaryLayoutReplacesChangedOutputBoundaryRuns() {
        #expect(OutputCleanup.preserveBoundaryLayout(from: "\nHello\t", in: "\tHello.\n") == "\nHello.\t")
    }

    @Test func boundaryLayoutDoesNotPreserveSpaces() {
        #expect(OutputCleanup.preserveBoundaryLayout(from: "  Hello  ", in: "Hello.") == "Hello.")
    }

    @Test func boundaryLayoutPreservesOnlyOuterLayoutCharacters() {
        #expect(OutputCleanup.preserveBoundaryLayout(from: "\nA\n\nB\t", in: "A\nB") == "\nA\nB\t")
    }
}
