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
}
