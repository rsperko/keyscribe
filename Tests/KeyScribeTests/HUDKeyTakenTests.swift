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

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode)!
    }

    private func commandW() -> NSEvent { key("w", keyCode: 13, modifiers: .command) }

    @Test func aKeyThePanelTakesIsReportedAndStillDelivered() {
        let hud = HUDController()
        var offered: [Int64] = []
        hud.onKeyTaken = { offered.append($0.getIntegerValueField(.keyboardEventKeycode)) }
        let event = commandW()
        #expect(hud.localKeyMonitorHandler(event) === event)
        #expect(offered == [13])
    }

    @Test func escapeThatCancelsIsConsumed() {
        let hud = HUDController()
        var cancels = 0
        hud.canCancel = { true }
        hud.onEscapeCancel = { cancels += 1 }
        #expect(hud.localKeyMonitorHandler(key("\u{1b}", keyCode: 53)) == nil)
        #expect(cancels == 1)
    }

    @Test func escapeWithNothingToCancelPassesThrough() {
        let hud = HUDController()
        hud.canCancel = { false }
        let escape = key("\u{1b}", keyCode: 53)
        #expect(hud.localKeyMonitorHandler(escape) === escape)
    }
}
