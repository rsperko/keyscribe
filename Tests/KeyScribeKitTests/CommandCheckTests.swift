import Testing
@testable import KeyScribeKit

struct CommandCheckTests {
    @Test func containsPasses() {
        let out = CommandCheck.evaluate(output: "one\ntwo", assertion: .init(contains: ["\n"]))
        #expect(out.passed)
    }

    @Test func containsFailsWithReadableControlChar() {
        let out = CommandCheck.evaluate(output: "one two", assertion: .init(contains: ["\n"]))
        #expect(!out.passed)
        #expect(out.failures == ["missing \"\\n\""])
    }

    @Test func absentPassesWhenTriggerConsumed() {
        let out = CommandCheck.evaluate(output: "one\ntwo", assertion: .init(absent: ["insert new line"]))
        #expect(out.passed)
    }

    @Test func absentDetectsSurvivingTriggerCaseInsensitively() {
        let out = CommandCheck.evaluate(output: "Insert New Line two", assertion: .init(absent: ["insert new line"]))
        #expect(!out.passed)
        #expect(out.failures == ["survived \"insert new line\""])
    }

    @Test func scratchNegativeLeavesPhraseAsText() {
        let out = CommandCheck.evaluate(
            output: "scratch that lottery ticket please",
            assertion: .init(contains: ["scratch that lottery ticket"]))
        #expect(out.passed)
    }

    @Test func equalsIsExactCaseForWholeUtteranceReplacement() {
        #expect(CommandCheck.evaluate(output: "/resume", assertion: .init(equals: "/resume")).passed)
        #expect(!CommandCheck.evaluate(output: "/Resume", assertion: .init(equals: "/resume")).passed)
    }

    @Test func noLeadingPunctFailsOnArtifact() {
        let out = CommandCheck.evaluate(
            output: "the path is. agent_notes/foo/ ok",
            assertion: .init(noLeadingPunct: "agent_notes/foo/"))
        #expect(!out.passed)
        #expect(out.failures == ["punctuation before \"agent_notes/foo/\""])
    }

    @Test func noLeadingPunctPassesWithCleanFold() {
        let out = CommandCheck.evaluate(
            output: "the path is agent_notes/foo/ ok",
            assertion: .init(noLeadingPunct: "agent_notes/foo/"))
        #expect(out.passed)
    }

    @Test func noLeadingPunctPassesAtStartOfOutput() {
        let out = CommandCheck.evaluate(output: "agent_notes/foo/ ok", assertion: .init(noLeadingPunct: "agent_notes/foo/"))
        #expect(out.passed)
    }

    @Test func failuresAccumulateAcrossKinds() {
        let out = CommandCheck.evaluate(
            output: "insert new line here",
            assertion: .init(contains: ["\n"], absent: ["insert new line"]))
        #expect(out.failures.count == 2)
    }

    @Test func emptyAssertionPasses() {
        #expect(CommandCheck.evaluate(output: "anything", assertion: .init()).passed)
    }
}
