import Testing
@testable import KeyScribeKit

struct InsertionDecisionTests {
    let mail = TargetSnapshot(bundleId: "com.apple.mail")

    @Test func sameAppNoFieldInfoInserts() {
        #expect(decideInsertion(captured: mail, current: mail) == .insert)
    }

    @Test func appChangedFallsBack() {
        let slack = TargetSnapshot(bundleId: "com.tinyspeck.slackmacgap")
        #expect(decideInsertion(captured: mail, current: slack) == .clipboardFallback(reason: .appChanged))
    }

    @Test func sameAppSameFieldInserts() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedElementId: "field-1")
        #expect(decideInsertion(captured: a, current: a) == .insert)
    }

    @Test func sameAppDifferentFieldFallsBack() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedElementId: "field-1")
        let b = TargetSnapshot(bundleId: "com.apple.mail", focusedElementId: "field-2")
        #expect(decideInsertion(captured: a, current: b) == .clipboardFallback(reason: .focusChanged))
    }

    @Test func sameAppFieldInfoLostInsertsBestEffort() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedElementId: "field-1")
        let b = TargetSnapshot(bundleId: "com.apple.mail", focusedElementId: nil)
        #expect(decideInsertion(captured: a, current: b) == .insert)
    }

    @Test func unknownCapturedTargetFallsBack() {
        let unknown = TargetSnapshot(bundleId: nil)
        #expect(decideInsertion(captured: unknown, current: mail) == .clipboardFallback(reason: .unknownTarget))
    }

    @Test func unverifiableCurrentTargetFallsBack() {
        #expect(decideInsertion(captured: mail, current: TargetSnapshot(bundleId: nil))
            == .clipboardFallback(reason: .appChanged))
    }

    @Test func insertActionHonorsPreferredMethod() {
        #expect(insertionAction(decision: .insert, method: .paste) == .paste)
        #expect(insertionAction(decision: .insert, method: .insert) == .ax)
        #expect(insertionAction(decision: .insert, method: .type) == .type)
    }

    @Test func clipboardFallbackOverridesEveryMethod() {
        for method in [Mode.Insertion.paste, .insert, .type] {
            #expect(insertionAction(decision: .clipboardFallback(reason: .appChanged), method: method) == .clipboard)
        }
    }
}
