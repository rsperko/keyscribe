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
}
