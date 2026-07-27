import AppKit
import Foundation
import KeyScribeKit

// Answers "will sharing text before the cursor actually work in the app I'm about to dictate into?"
// — the question the feature cannot answer for itself, because a caret path that returns nothing is
// indistinguishable from a field that is simply empty. Runs the REAL production read
// (ContextProbe.precedingText) and reports what it yielded, plus the focused role and the field facts
// derived from it. Reports character counts and roles, never field text.
@MainActor
enum ContextProbeTool {
    // Main-actor completion flag the CLI's run-loop pump polls (a blocking semaphore would starve
    // the main actor this tool runs on).
    final class Completion { var isDone = false; init() {} }

    static func run(countdown: Int) async {
        print("Focus the app and field you want to test — probing in \(countdown)s…")
        for remaining in stride(from: countdown, to: 0, by: -1) {
            print("  \(remaining)…")
            try? await Task.sleep(for: .seconds(1))
        }

        let front = NSWorkspace.shared.frontmostApplication
        guard let pid = front?.processIdentifier else {
            print("no frontmost application")
            return
        }
        let name = front?.localizedName ?? "?"
        let bundle = front?.bundleIdentifier ?? "?"
        print("\napp: \(name) [\(bundle)] pid=\(pid)")

        let snapshot = ContextProbe.snapshot()
        print("focused role: \(snapshot.focusedRole ?? "none")   secure field: \(snapshot.isSecureField)")
        let facts = FieldFacts.derive(role: snapshot.focusedRole)
        print("field facts: singleLine=\(facts.singleLine.map(String.init) ?? "unknown") plainText=\(facts.plainText.map(String.init) ?? "unknown")")

        if snapshot.isSecureField {
            print("\nverdict: SECURE FIELD — context is suppressed here by design, and no rewrite runs.")
            return
        }

        let text = await ContextProbe.precedingText(pid: pid, windowId: snapshot.focusedWindowId)
        print("  read: \(text.map { "\($0.count) chars" } ?? "nothing")")
        printVerdict(available: text != nil)
    }

    private static func printVerdict(available: Bool) {
        print("")
        if available {
            print("verdict: WORKS — this app shares text before the cursor right now.")
            print("  A mode with context enabled will send up to 600 chars, and screen terms will be")
            print("  harvested from it for local spelling recovery.")
            return
        }
        print("verdict: NO CONTEXT AVAILABLE in this app/field.")
        print("  Either the field is empty / the caret is at position 0 (retry with text before the")
        print("  cursor), or the app does not expose a caret range to accessibility at all.")
        print("  Known: stock VS Code (Monaco) never exposes editor text to a passive reader. Chromium")
        print("  browsers expose it only once their renderer accessibility is enabled, which is outside")
        print("  this app's control (agent_notes/web_editor_context).")
    }
}
