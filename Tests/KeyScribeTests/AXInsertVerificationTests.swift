import Testing
@testable import KeyScribe

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

    @Test func unchangedValueWithDifferentSelectionFallsBack() {
        #expect(!TextInserter.axInsertLandedInPlace(
            before: "hello", after: "hello", selectedBefore: "goodbye", selectedAfter: "", inserted: "hello"))
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
}
