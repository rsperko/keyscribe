import AppKit
import KeyScribeKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
struct ModeEditorBehaviorTests {
    private func menuTitles(_ view: NSView) -> [String] {
        ((view as? NSPopUpButton)?.itemTitles ?? []) + view.subviews.flatMap(menuTitles)
    }

    private func render(_ mode: Mode) -> [String] {
        let editor = ModeEditorView(
            mode: mode, allModes: [mode], connections: [], fragmentIds: [], fragmentNames: [:],
            onUpdate: { _ in }, onAddFragmentFile: { _ in nil }, onLoadFragmentBody: { _ in "" },
            onSaveFragmentBody: { _, _ in }, onCloseFragment: { _, _ in }, onRevealFragment: { _ in }, onDelete: {})
            .environmentObject(HotkeyRecordingState())
        let host = NSHostingView(rootView: editor.frame(width: 600, height: 1600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 1600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return menuTitles(host)
    }

    @Test(arguments: ["polish", "edit-selection", "ask-about-selection"])
    func noModeOffersToChangeWhatItDoes(seedId: String) throws {
        let mode = try #require(ModeStore.templates(askAboutSelection: true).first { $0.id == seedId })
        let titles = render(mode)
        for choice in ["Dictate at the cursor", "Edit selected text", "Answer about selected text"] {
            #expect(!titles.contains(choice))
        }
    }
}
