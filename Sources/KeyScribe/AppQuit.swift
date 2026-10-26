import AppKit

// Quit always quits. AppKit refuses to terminate while a sheet is attached or a modal dialog runs, which left
// Quit beeping behind a command sheet in a Settings window hidden by other apps. Anything unsaved in that
// sheet is discarded, as with any other quit.
@MainActor
final class AppQuit: NSObject {
    static let shared = AppQuit()

    private let windows: () -> [NSWindow]
    private let terminate: (Any?) -> Void

    init(windows: @escaping () -> [NSWindow] = { NSApp.windows }, terminate: @escaping (Any?) -> Void = { NSApp.terminate($0) }) {
        self.windows = windows
        self.terminate = terminate
    }

    // AppKit withholds menu actions from a custom target while a dialog runs modally unless it opts in.
    @objc var worksWhenModal: Bool { true }

    @objc func quit(_ sender: Any?) {
        guard NSApp.modalWindow == nil else {
            NSApp.abortModal()
            // The modal loop unwinds only once this action returns.
            nonisolated(unsafe) let sender = sender
            RunLoop.main.perform { MainActor.assumeIsolated { self.quit(sender) } }
            return
        }
        Self.closeModals(in: windows())
        terminate(sender)
    }

    // A SwiftUI sheet is re-presented as long as its state says it is open, so ending the sheet alone is not
    // enough: the window that held it is closed too, leaving nothing to present it into.
    static func closeModals(in windows: [NSWindow]) {
        for window in windows where window.attachedSheet != nil {
            endSheets(of: window)
            window.close()
        }
    }

    private static func endSheets(of window: NSWindow) {
        guard let sheet = window.attachedSheet else { return }
        endSheets(of: sheet)
        window.endSheet(sheet)
    }
}
