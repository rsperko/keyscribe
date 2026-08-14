import XCTest

@MainActor
final class SidebarNavigationTests: XCTestCase {
    private func launchIntoSettings(additionalArguments: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication(bundleIdentifier: "com.keyscribe.app.dev")
        app.launchArguments = ["--open-settings"] + additionalArguments
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
            ("settings.sidebar.general", "settings.general.editPlainDictation"),
            ("settings.sidebar.speechModels", "settings.speech.list"),
            ("settings.sidebar.vocabulary", "settings.vocabulary.composer.term"),
            ("settings.sidebar.aiServices", "settings.ai.list"),
            ("settings.sidebar.modes", "mode.list"),
            ("settings.sidebar.history", "history.search"),
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

    func testGeneralShowsGlobalShortcutsWithoutExpandingAnything() {
        let (_, window) = launchIntoSettings()

        for id in [
            "settings.general.addVocabularyShortcut",
            "settings.general.pasteLastShortcut",
        ] {
            let shortcut = element(id, in: window)
            XCTAssertTrue(shortcut.waitForExistence(timeout: 8), "\(id) should be visible in General")
            XCTAssertTrue(shortcut.isHittable, "\(id) should be available without expanding a section")
        }

        XCTAssertFalse(window.staticTexts["Both are also available from the KeyScribeDev menu."].exists,
                       "the Shortcuts section should not repeat menu availability")
    }

    func testGeneralPlainDictationSummaryOpensItsModeEditor() throws {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-general-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let (app, window) = launchIntoSettings(additionalArguments: ["--config-dir", config.path])
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: config)
        }

        XCTAssertTrue(window.staticTexts["Hold to talk; tap to toggle"].waitForExistence(timeout: 8),
                      "General should show the configured Plain Dictation press behavior")

        let edit = element("settings.general.editPlainDictation", in: window)
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        XCTAssertTrue(edit.isHittable)
        XCTAssertEqual(edit.label, "Edit Plain Dictation in Modes")
        edit.click()

        let pressBehavior = element("mode.editor.pressStyle", in: window)
        XCTAssertTrue(pressBehavior.waitForExistence(timeout: 8),
                      "editing Plain Dictation from General should open its mode editor")
        XCTAssertTrue(window.staticTexts["Plain Dictation is also used whenever no other mode matches."].exists,
                      "the Plain Dictation system mode should be selected")
    }

    func testGeneralMakesDuringDictationScopeVisible() {
        let (_, window) = launchIntoSettings()

        XCTAssertTrue(window.staticTexts["During dictation"].waitForExistence(timeout: 8),
                      "the audio and system options should say that they apply only during dictation")
        XCTAssertTrue(window.staticTexts["These settings apply only while you dictate."].exists,
                      "the audio and system options should explain their scope")
    }

    func testCueVolumeAppearsOnlyWhileSoundsAreEnabled() throws {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-sound-volume-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let (app, window) = launchIntoSettings(additionalArguments: ["--config-dir", config.path])
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: config)
        }

        let sounds = element("settings.general.sounds", in: window)
        let volume = element("settings.general.soundVolume", in: window)
        XCTAssertTrue(sounds.waitForExistence(timeout: 8))
        XCTAssertTrue(window.staticTexts["Sound feedback"].exists)
        XCTAssertTrue(window.staticTexts["Play dictation sounds"].exists)
        XCTAssertTrue(window.staticTexts["Dictation sounds volume"].exists)
        // A fragment, not the whole sentence: the footer's exact wording is copy, and pinning it verbatim
        // (curly apostrophe included) makes every copy edit a test failure.
        XCTAssertTrue(window.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Maximum plays them at full level")).firstMatch.exists)
        XCTAssertTrue(volume.waitForExistence(timeout: 8), "sound volume should appear when sounds are on")

        volume.adjust(toNormalizedSliderPosition: 0.25)
        let afterDrag = try sliderValue(volume)
        XCTAssertLessThan(afterDrag, 1, "the drag should have moved the slider off its maximum")

        sounds.click()
        XCTAssertFalse(volume.waitForExistence(timeout: 1), "sound volume should disappear when sounds are off")

        sounds.click()
        XCTAssertTrue(volume.waitForExistence(timeout: 3), "sound volume should come back when sounds return")
        XCTAssertEqual(try sliderValue(volume), afterDrag, accuracy: 0.001,
                       "hiding the slider must not reset the volume the user chose")
    }

    // A slider's AXValue is a CFNumber (verified live), so `value as? String` is ALWAYS nil and comparing
    // two of them is nil == nil — an assertion that cannot fail. Unwrap the number instead, so a value that
    // stops being readable fails the test rather than passing it vacuously.
    private func sliderValue(_ element: XCUIElement) throws -> Double {
        try XCTUnwrap(element.value as? NSNumber, "the volume slider must expose a numeric AX value")
            .doubleValue
    }

    func testAddAIServiceChooserHasVisibleCancelAction() {
        let (_, window) = launchIntoSettings()

        let aiServices = element("settings.sidebar.aiServices", in: window)
        XCTAssertTrue(aiServices.waitForExistence(timeout: 8))
        aiServices.click()

        let add = element("settings.ai.list.add", in: window)
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.click()

        let cancel = element("settings.ai.chooser.cancel", in: window)
        XCTAssertTrue(cancel.waitForExistence(timeout: 8),
                      "the Add AI Service chooser should offer a visible Cancel action")
        XCTAssertTrue(cancel.isHittable, "Cancel should be directly available in the chooser")
        cancel.click()
        XCTAssertFalse(cancel.waitForExistence(timeout: 3), "Cancel should dismiss the chooser")
    }

    func testAddModeChooserHasVisibleCancelAction() {
        let (_, window) = launchIntoSettings()

        let modes = element("settings.sidebar.modes", in: window)
        XCTAssertTrue(modes.waitForExistence(timeout: 8))
        modes.click()

        let add = element("mode.list.add", in: window)
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.click()

        let cancel = element("mode.chooser.cancel", in: window)
        XCTAssertTrue(cancel.waitForExistence(timeout: 8),
                      "the Add Mode chooser should offer a visible Cancel action")
        XCTAssertTrue(cancel.isHittable, "Cancel should be directly available in the chooser")
        cancel.click()
        XCTAssertFalse(cancel.waitForExistence(timeout: 3), "Cancel should dismiss the chooser")
    }
}
