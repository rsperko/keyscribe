import AppKit
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct HUDDragSnapTests {
    private func panel() -> HUDPanel {
        HUDPanel.make(content: NSView(), size: NSSize(width: 280, height: 64))
    }

    private func settle() async throws {
        try await Task.sleep(for: .seconds(HUDDragSnap.settle + 0.15))
    }

    @Test func aMoveSettlesIntoOneSnap() async throws {
        let panel = panel()
        var snaps = 0
        let snap = HUDDragSnap(panel: panel) { _ in snaps += 1 }
        panel.setFrameOrigin(NSPoint(x: 300, y: 300))
        panel.setFrameOrigin(NSPoint(x: 320, y: 310))
        try await settle()
        #expect(snaps == 1)
        _ = snap
    }

    @Test func aMoveTheControllerMakesIsNotADrag() async throws {
        let panel = panel()
        var snaps = 0
        let snap = HUDDragSnap(panel: panel) { _ in snaps += 1 }
        snap.place { panel.setFrameOrigin(NSPoint(x: 500, y: 200)) }
        try await settle()
        #expect(snaps == 0)
    }

    @Test func thePanelDragsFromItsBackgroundAndNeverBecomesMain() {
        let panel = panel()
        #expect(!panel.isMovableByWindowBackground)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.allowsKey = { false }
        #expect(!panel.canBecomeKey)
        panel.allowsKey = { true }
        #expect(panel.canBecomeKey)
    }
}
