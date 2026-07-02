import AppKit
import Testing
@testable import KeyScribe

@MainActor
struct MenuBarIconTests {
    @Test func statusIconIsTemplateSizedForTheMenuBar() {
        let image = MenuBarController.statusIcon

        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func updateAffordanceUsesAmberIndicator() {
        #expect(MenuBarController.updateTint.matches(.systemOrange))
        #expect(MenuBarController.updateIndicatorImage.isTemplate == false)
        #expect(MenuBarController.updateIndicatorImage.size == NSSize(width: 8, height: 8))
    }

    @Test func updateMenuItemCarriesIndicatorWhenAvailable() {
        let controller = MenuBarController()
        controller.install()

        controller.setUpdateAvailable(true)

        #expect(controller.updateItem.title == "Update Available…")
        #expect(controller.updateItem.image === MenuBarController.updateIndicatorImage)
    }

    // H1: without `autoenablesItems = false`, AppKit force-enables "Paste Last Dictation" at display
    // time (its target responds to its action), overriding `setHasResult(false)` — clicking it would
    // call `onPasteLast` with nothing to paste. `NSMenu.update()` runs the same validation pass AppKit
    // runs before showing the menu, without needing the menu to actually be on screen.
    @Test func pasteLastDictationStaysDisabledWithNoResultUnderMenuValidation() {
        let controller = MenuBarController()
        controller.install()
        controller.setHasResult(false)

        controller.mainMenu?.update()

        #expect(controller.mainMenu?.autoenablesItems == false)
        #expect(controller.pasteLastMenuItem.isEnabled == false)
    }

    @Test func pasteLastDictationEnablesWhenAResultExists() {
        let controller = MenuBarController()
        controller.install()
        controller.setHasResult(true)

        controller.mainMenu?.update()

        #expect(controller.pasteLastMenuItem.isEnabled == true)
    }
}

private extension NSColor {
    func matches(_ other: NSColor) -> Bool {
        guard
            let left = usingColorSpace(.sRGB),
            let right = other.usingColorSpace(.sRGB)
        else { return false }

        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
            && abs(left.alphaComponent - right.alphaComponent) < 0.001
    }
}
