import Foundation
import Testing
@testable import KeyScribeKit

struct SelectionTextTests {
    @Test func withPrivacyTheInstructionIsRedactedThroughTheSelectionsTokenizer() {
        let prepared = SelectionText(
            selection: "write to alice@example.com", instruction: "cc bob@example.com", liveEdits: true, privacy: true,
            trimsTrailingPunctuation: false)
        #expect(prepared.take.payload.issuedTokens.count == 1)
        #expect(prepared.instructionTokens.count == 1)
        #expect(!prepared.instruction.contains("bob@example.com"))
        #expect(prepared.take.pipeline.restore(prepared.instruction) == "cc bob@example.com")
    }

    @Test func withoutPrivacyTheInstructionIsSentAsSaid() {
        let prepared = SelectionText(
            selection: "alice@example.com", instruction: "cc bob@example.com", liveEdits: true, privacy: false,
            trimsTrailingPunctuation: false)
        #expect(prepared.instruction == "cc bob@example.com")
        #expect(prepared.instructionTokens.isEmpty)
        #expect(prepared.take.payload.issuedTokens.isEmpty)
    }

    @Test func noTextStagesTouchTheSelection() {
        let prepared = SelectionText(
            selection: "insert new line stays", instruction: "", liveEdits: true, privacy: false,
            trimsTrailingPunctuation: false)
        #expect(prepared.take.payload.text == "insert new line stays")
    }
}
