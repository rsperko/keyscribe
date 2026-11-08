import XCTest

@MainActor
final class VocabularySelectionUITests: XCTestCase {
    func testSharedVocabularyAndModeWithTheSameNameAndIDStayIndependent() throws {
        let config = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("keyscribe-vocabulary-selection-\(UUID().uuidString)", isDirectory: true)
        // A shared vocabulary takes its file id from the placeholder it is added under, so a mode named the same
        // placeholder shares the id, and renaming the vocabulary inline keeps it.
        let modeFile = config.appendingPathComponent("modes/new-vocabulary.toml")
        let sharedFile = config.appendingPathComponent("vocabularies/new-vocabulary.toml")

        let app = XCUIApplication(bundleIdentifier: "com.keyscribe.app.dev")
        app.launchArguments = ["--open-settings", "--config-dir", config.path]
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: config)
        }
        let window = app.windows["KeyScribeDev Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        // The app cannot read fixtures inside the sandboxed runner's container.
        element("settings.sidebar.modes", in: window).click()
        element("mode.list.add", in: window).click()
        let blank = window.buttons["New Blank Mode"]
        XCTAssertTrue(blank.waitForExistence(timeout: 8))
        blank.click()
        let name = element("mode.editor.name", in: window)
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("New Vocabulary\n")
        element("mode.editor.recognition.editVocabulary", in: window).click()
        addWord("ModeOnlyTerm", in: window)
        let originalMode = try String(contentsOf: modeFile, encoding: .utf8)
        element("settings.vocabulary.shared.add", in: window).click()
        let sharedName = element("settings.vocabulary.shared.name", in: window)
        XCTAssertTrue(sharedName.waitForExistence(timeout: 8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedFile.path))
        sharedName.typeKey("a", modifierFlags: .command)
        sharedName.typeText("Agent Terms")
        element("settings.vocabulary.shared.chooseModes", in: window).click()
        let apply = element("settings.vocabulary.shared.modesApply", in: window)
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        XCTAssertTrue(window.staticTexts["Choose Modes"].exists)
        XCTAssertTrue(try String(contentsOf: sharedFile, encoding: .utf8).contains("Agent Terms"))
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("settings.vocabulary.shared.usedBy", in: window).waitForExistence(timeout: 8))
        // Changing back to an earlier saved name is still a change, and still saved first.
        sharedName.click()
        sharedName.typeKey("a", modifierFlags: .command)
        sharedName.typeText("New Vocabulary")
        element("settings.vocabulary.shared.chooseModes", in: window).click()
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        XCTAssertTrue(try String(contentsOf: sharedFile, encoding: .utf8).contains("New Vocabulary"))
        XCTAssertFalse(try String(contentsOf: sharedFile, encoding: .utf8).contains("Agent Terms"))
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("settings.vocabulary.shared.usedBy", in: window).waitForExistence(timeout: 8))

        let modeRow = element("settings.vocabulary.scope.mode.new-vocabulary", in: window)
        XCTAssertTrue(modeRow.waitForExistence(timeout: 8))
        modeRow.click()
        let modeSharing = element("settings.vocabulary.mode.chooseShared", in: window)
        XCTAssertTrue(modeSharing.waitForExistence(timeout: 8))
        XCTAssertTrue(element("settings.vocabulary.dictionary.remove.ModeOnlyTerm", in: window).exists)

        let sharedRow = element("settings.vocabulary.scope.shared.new-vocabulary", in: window)
        XCTAssertTrue(sharedRow.waitForExistence(timeout: 8))
        sharedRow.click()
        let audience = element("settings.vocabulary.shared.usedBy", in: window)
        XCTAssertTrue(audience.waitForExistence(timeout: 8))
        XCTAssertFalse(element("settings.vocabulary.dictionary.remove.ModeOnlyTerm", in: window).exists)
        XCTAssertFalse(modeSharing.exists)

        addWord("SharedOnlyTerm", in: window)
        XCTAssertEqual(try String(contentsOf: modeFile, encoding: .utf8), originalMode)
        XCTAssertTrue(try String(contentsOf: sharedFile, encoding: .utf8).contains("SharedOnlyTerm"))

        modeRow.click()
        XCTAssertTrue(modeSharing.waitForExistence(timeout: 8))
        XCTAssertTrue(element("settings.vocabulary.dictionary.remove.ModeOnlyTerm", in: window).exists)
        XCTAssertFalse(element("settings.vocabulary.dictionary.remove.SharedOnlyTerm", in: window).exists)
        sharedRow.click()
        XCTAssertTrue(audience.waitForExistence(timeout: 8))
        XCTAssertTrue(element("settings.vocabulary.dictionary.remove.SharedOnlyTerm", in: window).exists)
    }

    private func addWord(_ word: String, in window: XCUIElement) {
        let term = element("settings.vocabulary.composer.term", in: window)
        XCTAssertTrue(term.waitForExistence(timeout: 8))
        term.click()
        term.typeText(word)
        element("settings.vocabulary.composer.add", in: window).click()
        XCTAssertTrue(element("settings.vocabulary.dictionary.remove.\(word)", in: window)
            .waitForExistence(timeout: 8))
    }

    private func element(_ id: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
