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

    @Test func sameAppSameWindowInserts() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedWindowId: "window-1")
        #expect(decideInsertion(captured: a, current: a) == .insert)
    }

    @Test func sameAppDifferentWindowFallsBack() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedWindowId: "window-1")
        let b = TargetSnapshot(bundleId: "com.apple.mail", focusedWindowId: "window-2")
        #expect(decideInsertion(captured: a, current: b) == .clipboardFallback(reason: .focusChanged))
    }

    @Test func sameAppWindowInfoLostInsertsBestEffort() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedWindowId: "window-1")
        let b = TargetSnapshot(bundleId: "com.apple.mail", focusedWindowId: nil)
        #expect(decideInsertion(captured: a, current: b) == .insert)
    }

    @Test func sameBundleDifferentPidFallsBack() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", pid: 100)
        let b = TargetSnapshot(bundleId: "com.apple.mail", pid: 200)
        #expect(decideInsertion(captured: a, current: b) == .clipboardFallback(reason: .appChanged))
    }

    @Test func sameBundleSamePidInserts() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", pid: 100)
        #expect(decideInsertion(captured: a, current: a) == .insert)
    }

    // A pid known on one side but missing on the other is indeterminate identity — divert, don't insert.
    @Test func pidLostOnOneSideFallsBack() {
        let withPid = TargetSnapshot(bundleId: "com.apple.mail", pid: 100)
        let noPid = TargetSnapshot(bundleId: "com.apple.mail", pid: nil)
        #expect(decideInsertion(captured: withPid, current: noPid) == .clipboardFallback(reason: .appChanged))
        #expect(decideInsertion(captured: noPid, current: withPid) == .clipboardFallback(reason: .appChanged))
    }

    // Two pid-less snapshots (no pid tracking at all) still fall through to the bundle/window checks.
    @Test func bothPidsUnknownInsertsBestEffort() {
        #expect(decideInsertion(captured: mail, current: mail) == .insert)
    }

    @Test func unknownCapturedTargetFallsBack() {
        let unknown = TargetSnapshot(bundleId: nil)
        #expect(decideInsertion(captured: unknown, current: mail) == .clipboardFallback(reason: .unknownTarget))
    }

    @Test func unverifiableCurrentTargetFallsBack() {
        #expect(decideInsertion(captured: mail, current: TargetSnapshot(bundleId: nil))
            == .clipboardFallback(reason: .appChanged))
    }

    @Test func currentSecureFieldFallsBack() {
        let secure = TargetSnapshot(bundleId: "com.apple.mail", isSecureField: true)
        #expect(decideInsertion(captured: mail, current: secure) == .clipboardFallback(reason: .secureField))
    }

    @Test func capturedSecureFieldFallsBack() {
        let secure = TargetSnapshot(bundleId: "com.apple.mail", isSecureField: true)
        #expect(decideInsertion(captured: secure, current: mail) == .clipboardFallback(reason: .secureField))
    }

    @Test func secureFieldBeatsMatchingAppAndWindow() {
        let a = TargetSnapshot(bundleId: "com.apple.mail", focusedWindowId: "window-1", isSecureField: true)
        #expect(decideInsertion(captured: a, current: a) == .clipboardFallback(reason: .secureField))
    }

    @Test func secureFieldClipboardOverridesEveryMethod() {
        for method in [Mode.Insertion.paste, .insert, .type] {
            #expect(insertionAction(decision: .clipboardFallback(reason: .secureField), method: method) == .clipboard)
        }
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

    @Test func pasteLastDivertsWhenAccessibilityDenied() {
        #expect(pasteLastDivertsToClipboard(
            frontmostBundleId: "com.apple.mail", ownBundleId: "com.keyscribe.app", accessibilityGranted: false))
    }

    @Test func pasteLastDivertsWhenKeyScribeIsFrontmost() {
        #expect(pasteLastDivertsToClipboard(
            frontmostBundleId: "com.keyscribe.app", ownBundleId: "com.keyscribe.app", accessibilityGranted: true))
    }

    @Test func pasteLastPastesIntoAnotherFrontmostApp() {
        #expect(!pasteLastDivertsToClipboard(
            frontmostBundleId: "com.apple.mail", ownBundleId: "com.keyscribe.app", accessibilityGranted: true))
    }

    @Test func pasteLastPastesWhenFrontmostUnknown() {
        #expect(!pasteLastDivertsToClipboard(
            frontmostBundleId: nil, ownBundleId: "com.keyscribe.app", accessibilityGranted: true))
    }
}
