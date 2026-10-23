import Testing
@testable import KeyScribeApp

@MainActor
struct AXInsertVerificationTests {
    @Test func changedValueVerifies() {
        #expect(TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello world", selectedBefore: "", selectedAfter: "", inserted: " world"))
    }

    @Test func unchangedValueWithCollapsedIdenticalSelectionVerifies() {
        #expect(TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello", selectedBefore: "hello", selectedAfter: "", inserted: "hello"))
    }

    @Test func unchangedValueWithSelectionStillIntactFallsBack() {
        #expect(!TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello", selectedBefore: "hello", selectedAfter: "hello", inserted: "hello"))
    }

    @Test func unchangedValueWithUnreadableSelectionBeforeFallsBack() {
        #expect(!TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello", selectedBefore: nil, selectedAfter: "", inserted: "hello"))
    }

    @Test func unchangedValueWithUnreadableSelectionAfterFallsBack() {
        #expect(!TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello", selectedBefore: "hello", selectedAfter: nil, inserted: "hello"))
    }

    @Test func unreadableAfterValueVerifiesOnlyWithSelectionEvidence() {
        #expect(TextInserter.axInsertLandedInPlace(
            before: "hello", after: nil, selectedBefore: "hello", selectedAfter: "", inserted: "hello"))
        #expect(!TextInserter.axInsertLandedInPlace(
            before: "hello", after: nil, selectedBefore: "hello", selectedAfter: "hello", inserted: "hello"))
    }

    @Test func emptyInsertionNeverVerifiesOnUnchangedValue() {
        #expect(!TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello", selectedBefore: "", selectedAfter: "", inserted: ""))
    }

    @Test func aTimedOutWriteWithNoReadBackIsUncertainRatherThanFailed() {
        #expect(TextInserter.axInsertOutcome(
            written: .cannotComplete, before: "hello", after: nil, selectedBefore: "", selectedAfter: nil,
            inserted: " world") == .uncertain)
    }

    @Test func aTimedOutWriteTheReadBackShowsLandedIsLanded() {
        #expect(TextInserter.axInsertOutcome(
            written: .cannotComplete, before: "hello", after: "hello world", selectedBefore: "", selectedAfter: "",
            inserted: " world") == .landed)
    }

    @Test func aTimedOutWriteTheAppAnsweredUnchangedFallsBack() {
        #expect(TextInserter.axInsertOutcome(
            written: .cannotComplete, before: "hello", after: "hello", selectedBefore: "", selectedAfter: "",
            inserted: " world") == .notLanded)
    }

    @Test func aCompletedWriteWithNoReadBackIsUncertainRatherThanPastedAgain() {
        #expect(TextInserter.axInsertOutcome(
            written: .success, before: "hello", after: nil, selectedBefore: "", selectedAfter: nil,
            inserted: " world") == .uncertain)
    }

    @Test func aCompletedWriteTheAppReadsBackUnchangedFallsBack() {
        #expect(TextInserter.axInsertOutcome(
            written: .success, before: "hello", after: "hello", selectedBefore: "", selectedAfter: "",
            inserted: " world") == .notLanded)
    }

    @Test func aRefusedWriteFallsBackWithoutConsultingTheReadBack() {
        #expect(TextInserter.axInsertOutcome(
            written: .attributeUnsupported, before: "hello", after: nil, selectedBefore: "", selectedAfter: nil,
            inserted: " world") == .notLanded)
    }
}
