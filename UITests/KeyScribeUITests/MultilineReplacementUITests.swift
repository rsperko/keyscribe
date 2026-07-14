import XCTest

@MainActor
final class MultilineReplacementUITests: XCTestCase {
    private func launch() throws -> (XCUIApplication, XCUIElement, URL) {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-multiline-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        schema_version = 1

        [[rules]]
        heard = 'signature'
        replace = '''first line
        second line'''
        regex = false
        """.write(to: config.appendingPathComponent("replacements.toml"), atomically: true, encoding: .utf8)
        let app = XCUIApplication(bundleIdentifier: "com.keyscribe.app.dev")
        app.launchArguments = ["--open-settings", "--config-dir", config.path]
        app.launch()
        let window = app.windows["KeyScribeDev Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        return (app, window, config)
    }

    private func element(_ id: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testSettingsComposerLabelsAndExpandsReplacementField() throws {
        let (_, window, config) = try launch()
        defer { try? FileManager.default.removeItem(at: config) }
        element("settings.sidebar.vocabulary", in: window).click()
        let label = window.staticTexts["Use instead (optional)"]
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        let expand = element("settings.vocabulary.composer.useInstead.expand", in: window)
        XCTAssertTrue(expand.waitForExistence(timeout: 8))
        XCTAssertLessThan(abs(expand.frame.midY - label.frame.midY), 4)
        XCTAssertGreaterThan(expand.frame.minX, label.frame.maxX)
        XCTAssertLessThan(expand.frame.minX - label.frame.maxX, 16)
        expand.click()
        let editor = element("settings.vocabulary.composer.useInstead.editor", in: window)
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.click()
        editor.typeText("first\nsecond")
        XCTAssertEqual(editor.value as? String, "first\nsecond")
        let done = element("settings.vocabulary.composer.useInstead.editorDone", in: window)
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.click()
        XCTAssertEqual(element("settings.vocabulary.composer.useInstead", in: window).value as? String,
                       "first\nsecond")
        let stored = try String(contentsOf: config.appendingPathComponent("replacements.toml"), encoding: .utf8)
        XCTAssertFalse(stored.contains("first\nsecond"))
    }

    func testSavedRuleEditorUsesInlineLargeEditor() throws {
        let (_, window, config) = try launch()
        defer { try? FileManager.default.removeItem(at: config) }
        element("settings.sidebar.vocabulary", in: window).click()
        let edit = element("settings.vocabulary.replacements.edit.0", in: window)
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.click()
        let editor = element("settings.vocabulary.replacements.editor.useInstead", in: window)
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(editor.frame.height, 100)
        XCTAssertFalse(element("settings.vocabulary.replacements.editor.useInstead.expand", in: window).exists)
    }
}
