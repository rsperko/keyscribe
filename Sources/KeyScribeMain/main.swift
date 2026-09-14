import AppKit
import KeyScribeApp
import KeyScribeKit
#if KEYSCRIBE_SPARKLE
import KeyScribeSparkle
#endif

DevCLI.handleFlags()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.mainMenu = EditMenu.make()
    let delegate = AppDelegate()
    // KEYSCRIBE_SPARKLE is a per-target compilation condition set only on the public app target in
    // App/project.yml. Not `canImport`: once the public target has built, its KeyScribeSparkle module
    // sits in shared DerivedData and `canImport` reads true for the dev target too.
    #if KEYSCRIBE_SPARKLE
    if AppVariant(bundleID: Bundle.main.bundleIdentifier).injectsBundledUpdater {
        delegate.updater = SparkleUpdater()
    }
    #endif
    app.delegate = delegate
    app.run()
}
