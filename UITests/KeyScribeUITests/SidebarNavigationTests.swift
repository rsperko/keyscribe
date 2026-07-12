import XCTest

@MainActor
final class SidebarNavigationTests: XCTestCase {
    private func launchIntoSettings() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication(bundleIdentifier: "com.keyscribe.app.dev")
        app.launchArguments = ["--open-settings"]
        app.launch()
        let window = app.windows["KeyScribeDev Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 20),
                      "Settings window should open via --open-settings")
        return (app, window)
    }

    private func element(_ id: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    // Selecting each sidebar row by its settings.sidebar.<pane> identifier must swap the detail pane.
    // The detail probe is a stable identifier unique to that pane, so a pass proves the click actually
    // moved the SwiftUI List selection AND the detail view followed -- the thing that was always flaky.
    func testEverySidebarPaneSelectsAndRendersDetail() {
        let (_, window) = launchIntoSettings()

        let panes: [(sidebar: String, detailProbe: String)] = [
            ("settings.sidebar.general", "settings.general.dictationTrigger"),
            ("settings.sidebar.speechModels", "settings.speech.list"),
            ("settings.sidebar.vocabulary", "settings.vocabulary.composer.term"),
            ("settings.sidebar.aiServices", "settings.ai.list"),
            ("settings.sidebar.modes", "mode.list"),
            ("settings.sidebar.history", "settings.general.historyEnabled"),
            ("settings.sidebar.permissions", "settings.permissions.row.microphone"),
            ("settings.sidebar.advanced", "settings.advanced.revealConfig"),
        ]

        for pane in panes {
            let row = element(pane.sidebar, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 8), "sidebar row \(pane.sidebar) should exist")
            row.click()

            let probe = pane.detailProbe
            let detail = element(probe, in: window)
            XCTAssertTrue(detail.waitForExistence(timeout: 8),
                          "selecting \(pane.sidebar) should render detail probe \(probe)")
        }
    }

    func testGeneralShowsAllShortcutsWithoutExpandingAnything() {
        let (_, window) = launchIntoSettings()

        for id in [
            "settings.general.dictationTrigger",
            "settings.general.addVocabularyShortcut",
            "settings.general.pasteLastShortcut",
        ] {
            let shortcut = element(id, in: window)
            XCTAssertTrue(shortcut.waitForExistence(timeout: 8), "\(id) should be visible in General")
            XCTAssertTrue(shortcut.isHittable, "\(id) should be available without expanding a section")
        }
    }
}
