import XCTest

// Self-generating UI map. Walks every Settings pane (and the mode editor), and for each writes
//   UITests/map/<pane>.json  — every element's identifier + role + frame + value + enabled + label
//   UITests/map/<pane>.png   — a screenshot of the window
// so an agent can read "what is where, what it's called, what it's set to, and see it" without guessing.
// The same walk is the live half of the addressing audit: any INTERACTIVE element with an empty
// identifier is collected into map/_gaps.json — those are controls no automation can address by id.
//
// Output dir is derived from #filePath (this source builds on the same machine that runs the suite),
// so there is no env plumbing. Run: scripts/ui-test.sh run -only-testing:KeyScribeUITests/InventoryDumpTests
@MainActor
final class InventoryDumpTests: XCTestCase {
    private var mapDir: URL {
        // .../UITests/KeyScribeUITests/InventoryDumpTests.swift -> .../UITests/map
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("map")
    }

    private let panes: [(pane: String, sidebar: String, probe: String)] = [
        ("general", "settings.sidebar.general", "settings.general.dictationTrigger"),
        ("speechModels", "settings.sidebar.speechModels", "settings.speech.list"),
        ("vocabulary", "settings.sidebar.vocabulary", "settings.vocabulary.composer.term"),
        ("aiServices", "settings.sidebar.aiServices", "settings.ai.list"),
        ("modes", "settings.sidebar.modes", "mode.list"),
        ("history", "settings.sidebar.history", "history.search"),
        ("permissions", "settings.sidebar.permissions", "settings.permissions.row.microphone"),
        ("advanced", "settings.sidebar.advanced", "settings.advanced.revealConfig"),
    ]

    func testDumpEveryPaneToMap() throws {
        try? FileManager.default.createDirectory(at: mapDir, withIntermediateDirectories: true)

        let app = XCUIApplication(bundleIdentifier: "com.keyscribe.app.dev")
        app.launchArguments = ["--open-settings"]
        app.launch()
        let window = app.windows["KeyScribeDev Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Settings window should open")

        var allGaps: [[String: Any]] = []

        for entry in panes {
            let row = window.descendants(matching: .any).matching(identifier: entry.sidebar).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8), "sidebar row \(entry.sidebar) missing")
            row.click()
            let probe = window.descendants(matching: .any).matching(identifier: entry.probe).firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 8), "pane \(entry.pane) did not render")

            allGaps += dump(window: window, pane: entry.pane)

            // The modes pane's editor holds a large share of the fields (routing, AI, recognition):
            // select the first real mode row so the editor renders, then dump it too.
            if entry.pane == "modes" {
                if let rowID = firstIdentifier(inWindow: window, withPrefix: "mode.list.row.") {
                    window.descendants(matching: .any).matching(identifier: rowID).firstMatch.click()
                    let editor = window.descendants(matching: .any)
                        .matching(identifier: "mode.editor.shortcutWell").firstMatch
                    if editor.waitForExistence(timeout: 6) {
                        allGaps += dump(window: window, pane: "modeEditor")
                    }
                }
            }
        }

        write(allGaps, to: "_gaps.json")
        print("[InventoryDump] wrote map to \(mapDir.path) — \(allGaps.count) unaddressed interactive controls")
    }

    // MARK: - dump one surface

    private func dump(window: XCUIElement, pane: String) -> [[String: Any]] {
        let snapshot = try? window.snapshot()
        var elements: [[String: Any]] = []
        var gaps: [[String: Any]] = []
        if let snapshot {
            walk(snapshot, pane: pane, into: &elements, gaps: &gaps)
        }
        write(["pane": pane, "elements": elements], to: "\(pane).json")

        let shot = window.screenshot()
        let png = mapDir.appendingPathComponent("\(pane).png")
        try? shot.pngRepresentation.write(to: png)
        return gaps
    }

    private func walk(
        _ node: XCUIElementSnapshot, pane: String,
        into elements: inout [[String: Any]], gaps: inout [[String: Any]]
    ) {
        let id = node.identifier
        let role = roleName(node.elementType)
        let f = node.frame
        var entry: [String: Any] = [
            "id": id,
            "role": role,
            "enabled": node.isEnabled,
            "frame": ["x": Int(f.minX), "y": Int(f.minY), "w": Int(f.width), "h": Int(f.height)],
        ]
        if !node.label.isEmpty { entry["label"] = node.label }
        if let value = node.value { entry["value"] = String(describing: value) }
        // Only record elements that carry an id OR are an interactive control — skip the thousands of
        // anonymous layout containers, which would drown the map.
        let interactive = isInteractive(node.elementType)
        if !id.isEmpty || interactive {
            elements.append(entry)
        }
        if interactive && id.isEmpty {
            gaps.append(["pane": pane, "role": role, "label": node.label,
                         "frame": entry["frame"] as Any])
        }
        for child in node.children {
            walk(child, pane: pane, into: &elements, gaps: &gaps)
        }
    }

    private func firstIdentifier(inWindow window: XCUIElement, withPrefix prefix: String) -> String? {
        guard let snapshot = try? window.snapshot() else { return nil }
        var found: String?
        func search(_ n: XCUIElementSnapshot) {
            if found != nil { return }
            if n.identifier.hasPrefix(prefix) { found = n.identifier; return }
            for c in n.children { search(c) }
        }
        search(snapshot)
        return found
    }

    // MARK: - element type helpers

    private func isInteractive(_ type: XCUIElement.ElementType) -> Bool {
        switch type {
        case .button, .checkBox, .radioButton, .textField, .secureTextField, .textView,
             .popUpButton, .menuButton, .slider, .stepper, .segmentedControl, .comboBox,
             .switch, .link, .menuItem, .disclosureTriangle, .toolbarButton:
            return true
        default:
            return false
        }
    }

    private func roleName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .checkBox: return "checkBox"
        case .radioButton: return "radioButton"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .popUpButton: return "popUpButton"
        case .menuButton: return "menuButton"
        case .comboBox: return "comboBox"
        case .slider: return "slider"
        case .stepper: return "stepper"
        case .segmentedControl: return "segmentedControl"
        case .switch: return "switch"
        case .link: return "link"
        case .menuItem: return "menuItem"
        case .disclosureTriangle: return "disclosureTriangle"
        case .toolbarButton: return "toolbarButton"
        case .staticText: return "staticText"
        case .image: return "image"
        case .cell: return "cell"
        case .table, .outline: return "table"
        case .group: return "group"
        case .scrollView: return "scrollView"
        case .other: return "other"
        case .window: return "window"
        default: return "type\(type.rawValue)"
        }
    }

    private func write(_ object: Any, to name: String) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? data.write(to: mapDir.appendingPathComponent(name))
    }
}
