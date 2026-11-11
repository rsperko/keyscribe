import AppKit
import Testing
@testable import KeyScribeApp

@MainActor
struct HUDKeyTakenTests {
    @Test func aKeyForThePanelOrForNoWindowWasTakenByTheHUD() {
        let panel = NSPanel()
        let other = NSWindow()
        #expect(HUDController.tookKey(eventWindow: panel, panel: panel))
        #expect(HUDController.tookKey(eventWindow: nil, panel: panel))
        #expect(!HUDController.tookKey(eventWindow: other, panel: panel))
    }
}
