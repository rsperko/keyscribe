import AppKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
@Suite(.serialized)
struct AppQuitTests {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test func closingModalsDetachesEverySheetIncludingOneOnASheet() {
        let settings = window()
        let sheet = window()
        let alert = window()
        settings.beginSheet(sheet)
        sheet.beginSheet(alert)
        #expect(settings.attachedSheet === sheet)
        AppQuit.closeModals(in: [settings])
        #expect(settings.attachedSheet == nil)
        #expect(sheet.attachedSheet == nil)
    }

    @Test func aSwiftUISheetCannotComeBackOnceItsWindowIsClosed() {
        let settings = window()
        settings.contentView = NSHostingView(rootView: Color.clear.sheet(isPresented: .constant(true)) {
            Color.clear.frame(width: 200, height: 100)
        })
        settings.orderFront(nil)
        defer { settings.orderOut(nil) }
        spin { settings.attachedSheet != nil }
        #expect(settings.attachedSheet != nil)
        AppQuit.closeModals(in: [settings])
        spin { false }
        #expect(settings.attachedSheet == nil)
    }

    @Test func quitReachesItsHandlerFromInsideAModalDialog() {
        var terminated = 0
        let quit = AppQuit(windows: { [] }, terminate: { _ in terminated += 1 })
        let item = NSMenuItem(title: "Quit", action: #selector(AppQuit.quit(_:)), keyEquivalent: "q")
        item.target = quit
        nonisolated(unsafe) let menu = NSMenu()
        menu.addItem(item)
        let dialog = window()
        let session = NSApplication.shared.beginModalSession(for: dialog)
        #expect(NSApp.modalWindow === dialog)
        nonisolated(unsafe) let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: dialog.windowNumber,
            context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
        // Pressed from inside a run loop the test owns, as a real key press arrives: aborting the modal stops the
        // innermost run loop, which must not be the test runner's own.
        nonisolated(unsafe) var handled = false
        RunLoop.main.perform { MainActor.assumeIsolated { handled = menu.performKeyEquivalent(with: event) } }
        spin { handled }
        let response = NSApp.runModalSession(session)
        NSApp.endModalSession(session)
        spin { terminated > 0 }
        #expect(handled)
        #expect(response == .abort)
        #expect(terminated == 1)
    }

    @Test func everyQuitItemUsesTheQuitThatClosesModals() {
        let controller = MenuBarController()
        controller.install()
        let statusQuit = controller.mainMenu?.items.last
        let appQuit = EditMenu.make().items.first?.submenu?.items.first { $0.keyEquivalent == "q" }
        for item in [statusQuit, appQuit] {
            #expect(item?.target === AppQuit.shared)
            #expect(item?.action == #selector(AppQuit.quit(_:)))
            #expect(item?.keyEquivalentModifierMask == .command)
        }
    }
}
