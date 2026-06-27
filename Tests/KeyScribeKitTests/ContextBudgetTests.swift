import Testing
@testable import KeyScribeKit

struct ContextBudgetTests {
    @Test func maxTokensReturnsFloorForShortSelection() {
        #expect(ContextBudget.maxTokens(forSelectionChars: 100, floor: 2048) == 2048)
    }

    @Test func maxTokensScalesAboveFloorForLongSelection() {
        let t = ContextBudget.maxTokens(forSelectionChars: 20_000, floor: 2048)
        #expect(t > 2048)
        // ~ 20000/4 * 1.25 = 6250
        #expect(t == 6250)
    }
}
