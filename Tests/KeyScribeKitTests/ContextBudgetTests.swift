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

    // ---- fit: priority budgeting (prompt_design.md §Context & token budget) ----

    @Test func fitKeepsFullVisibleTextWhenItFits() {
        let r = ContextBudget.fit(mandatoryChars: 100, visibleText: "surrounding context",
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .ok(.init(visibleText: "surrounding context", visibleDisposition: .kept)))
    }

    @Test func fitTruncatesVisibleTextToCap() {
        let v = String(repeating: "a", count: 5_000)
        let r = ContextBudget.fit(mandatoryChars: 100, visibleText: v,
                                  budgetChars: 100_000, visibleCap: 4_000)
        guard case let .ok(fit) = r else { Issue.record("expected ok"); return }
        #expect(fit.visibleDisposition == .truncated)
        #expect(fit.visibleText?.count == 4_000)
    }

    @Test func fitTruncatesToRemainingWhenTighterThanCap() {
        let v = String(repeating: "a", count: 5_000)
        // remaining = 1000, smaller than the 4000 cap → cap to remaining.
        let r = ContextBudget.fit(mandatoryChars: 9_000, visibleText: v,
                                  budgetChars: 10_000, visibleCap: 4_000)
        guard case let .ok(fit) = r else { Issue.record("expected ok"); return }
        #expect(fit.visibleDisposition == .truncated)
        #expect(fit.visibleText?.count == 1_000)
    }

    @Test func fitDropsVisibleTextWhenNoRoom() {
        // Mandatory content fills the budget exactly — no room for any visible text.
        let r = ContextBudget.fit(mandatoryChars: 10_000, visibleText: "context",
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .ok(.init(visibleText: nil, visibleDisposition: .dropped)))
    }

    @Test func fitRefusesWhenMandatoryExceedsBudget() {
        // Instructions + content + selection don't fit → refuse, never cut them.
        let r = ContextBudget.fit(mandatoryChars: 12_000, visibleText: nil,
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .refuse)
    }

    @Test func fitRefusesEvenWhenVisibleTextPresent() {
        let r = ContextBudget.fit(mandatoryChars: 12_000, visibleText: "context",
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .refuse)
    }

    @Test func fitWithNoVisibleTextIsAbsent() {
        let r = ContextBudget.fit(mandatoryChars: 100, visibleText: nil,
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .ok(.init(visibleText: nil, visibleDisposition: .absent)))
    }

    @Test func fitTreatsWhitespaceVisibleTextAsAbsent() {
        let r = ContextBudget.fit(mandatoryChars: 100, visibleText: "   \n  ",
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .ok(.init(visibleText: nil, visibleDisposition: .absent)))
    }

    @Test func fitTrimsVisibleTextBeforeMeasuring() {
        let r = ContextBudget.fit(mandatoryChars: 100, visibleText: "  hello  ",
                                  budgetChars: 10_000, visibleCap: 4_000)
        #expect(r == .ok(.init(visibleText: "hello", visibleDisposition: .kept)))
    }
}
