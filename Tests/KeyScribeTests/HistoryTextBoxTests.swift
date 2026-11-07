import AppKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
struct HistoryTextBoxTests {
    private func boxHeight(_ text: String) -> CGFloat {
        let pane = ComparisonPane(
            title: "Heard", role: .heard, spans: [.init(id: 0, text: text, kind: .unchanged)], onSelect: { _, _ in })
        let host = NSHostingView(rootView: pane.frame(width: 500))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func aTextBoxIsAsTallAsItsTextSoAShortTakeLeavesNoEmptySpace() {
        let short = boxHeight("Tell rsperko green to say hi.")
        let long = boxHeight(Array(repeating: "Create a note called groceries that says buy milk.", count: 12).joined(separator: " "))
        #expect(short < 80)
        #expect(long > short + 60)
    }
}
