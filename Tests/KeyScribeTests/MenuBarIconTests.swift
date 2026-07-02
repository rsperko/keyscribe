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
