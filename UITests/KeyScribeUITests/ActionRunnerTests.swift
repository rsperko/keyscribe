import XCTest

// Generic, agent-driveable actuator. Instead of a hand-written test per interaction, this ONE test
// reads a JSON action script and executes it against the live Settings UI, addressing controls by the
// AccessibilityID catalog. An agent authors the script, runs it, and reads the per-step results +
// screenshots back — no recompile per interaction.
//
// Input: the script arrives as base64-encoded JSON in the KEYSCRIBE_UI_SCRIPT_B64 environment variable
// (the sandboxed runner cannot read an arbitrary file path, so the script is passed inline, not by path).
// scripts/ui-drive.sh <script.json> encodes it and runs this test.
//
// Script = a JSON array of steps. Supported actions (address controls by their catalog identifier):
//   {"action":"selectPane","pane":"aiServices"}           select a sidebar pane (bare suffix or full id)
//   {"action":"click","id":"settings.ai.list.add"}        click / press
//   {"action":"setValue","id":"...","value":"text"}       focus, clear, type (replace field contents)
//   {"action":"typeText","id":"...","text":"more"}        focus, type (append)
//   {"action":"exists","id":"...","timeout":3}            assert existence (records ok=false if absent)
//   {"action":"dump","name":"after-add"}                  attach a JSON snapshot of the window's ided/interactive elements
//   {"action":"screenshot","name":"step2"}                attach a PNG of the window
//
// Output (extracted from the .xcresult by scripts/ui-drive.sh):
//   _actions.json          per-step results [{index, action, id?, ok, value?, note?}]
//   step-<i>-<action>.png  a screenshot after every step
//   dump-<name>.json       for each dump step
@MainActor
final class ActionRunnerTests: XCTestCase {
    func testRunScript() throws {
        let script = try loadScript()
        guard !script.isEmpty else {
            throw XCTSkip("No KEYSCRIBE_UI_SCRIPT_B64 provided — nothing to drive. Use scripts/ui-drive.sh <script.json>.")
        }

        let app = XCUIApplication(bundleIdentifier: "com.keyscribe.app.dev")
        app.launchArguments = ["--open-settings"]
        app.launch()
        let window = app.windows["KeyScribeDev Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Settings window should open")

        var results: [[String: Any]] = []
        for (i, step) in script.enumerated() {
            results.append(execute(step, index: i, window: window))
        }

        attachJSON(results, name: "_actions.json")
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8) {
            print("[ActionRunner] RESULTS_BEGIN\n\(json)\nRESULTS_END")
        }
    }

    // MARK: - one step

    private func execute(_ step: [String: Any], index: Int, window: XCUIElement) -> [String: Any] {
        let action = step["action"] as? String ?? ""
        let id = step["id"] as? String
        func el(_ ident: String) -> XCUIElement {
            window.descendants(matching: .any).matching(identifier: ident).firstMatch
        }
        var ok = true
        var note = ""

        switch action {
        case "selectPane":
            let pane = step["pane"] as? String ?? ""
            let ident = pane.contains(".") ? pane : "settings.sidebar.\(pane)"
            let row = el(ident)
            ok = row.waitForExistence(timeout: 8)
            if ok { row.click() } else { note = "sidebar \(ident) not found" }

        case "click":
            if let id { let e = el(id); ok = e.waitForExistence(timeout: 8); if ok { e.click() } else { note = "\(id) not found" } }
            else { ok = false; note = "missing id" }

        case "setValue":
            if let id {
                let e = el(id); ok = e.waitForExistence(timeout: 8)
                if ok {
                    e.click()
                    e.typeKey("a", modifierFlags: .command)
                    e.typeText(String(XCUIKeyboardKey.delete.rawValue))
                    e.typeText(step["value"] as? String ?? "")
                } else { note = "\(id) not found" }
            } else { ok = false; note = "missing id" }

        case "typeText":
            if let id {
                let e = el(id); ok = e.waitForExistence(timeout: 8)
                if ok { e.click(); e.typeText(step["text"] as? String ?? "") } else { note = "\(id) not found" }
            } else { ok = false; note = "missing id" }

        case "exists":
            if let id { ok = el(id).waitForExistence(timeout: (step["timeout"] as? Double) ?? 3) }
            else { ok = false; note = "missing id" }

        case "dump":
            let name = step["name"] as? String ?? "step\(index)"
            dumpWindow(window, name: "dump-\(name).json")

        case "screenshot":
            break // handled by the per-step screenshot below

        default:
            ok = false; note = "unknown action \"\(action)\""
        }

        // A screenshot after every step so the agent can see the progression.
        let shot = window.screenshot()
        let png = XCTAttachment(uniformTypeIdentifier: "public.png",
                                name: "step-\(index)-\(action).png", payload: shot.pngRepresentation)
        png.lifetime = .keepAlways
        add(png)

        var result: [String: Any] = ["index": index, "action": action, "ok": ok]
        if let id {
            result["id"] = id
            let v = el(id).value
            if let v { result["value"] = String(describing: v) }
        }
        if !note.isEmpty { result["note"] = note }
        return result
    }

    // MARK: - helpers

    private func loadScript() throws -> [[String: Any]] {
        guard let b64 = ProcessInfo.processInfo.environment["KEYSCRIBE_UI_SCRIPT_B64"],
              !b64.isEmpty, let data = Data(base64Encoded: b64) else { return [] }
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [[String: Any]]) ?? []
    }

    private func dumpWindow(_ window: XCUIElement, name: String) {
        guard let snapshot = try? window.snapshot() else { return }
        var elements: [[String: Any]] = []
        func walk(_ n: XCUIElementSnapshot) {
            if !n.identifier.isEmpty {
                let f = n.frame
                var e: [String: Any] = [
                    "id": n.identifier, "enabled": n.isEnabled,
                    "frame": ["x": Int(f.minX), "y": Int(f.minY), "w": Int(f.width), "h": Int(f.height)],
                ]
                if !n.label.isEmpty { e["label"] = n.label }
                if let v = n.value { e["value"] = String(describing: v) }
                elements.append(e)
            }
            for c in n.children { walk(c) }
        }
        walk(snapshot)
        attachJSON(["elements": elements], name: name)
    }

    private func attachJSON(_ object: Any, name: String) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        let att = XCTAttachment(uniformTypeIdentifier: "public.json", name: name, payload: data)
        att.lifetime = .keepAlways
        add(att)
    }
}
