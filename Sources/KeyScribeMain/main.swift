import AppKit
import KeyScribeApp

DevCLI.handleFlags()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.mainMenu = EditMenu.make()
    let delegate = AppDelegate()
    delegate.attachBundledUpdater()
    app.delegate = delegate
    app.run()
}
