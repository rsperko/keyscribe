import Foundation
import KeyScribeKit

enum KeyScribePaths {
    // Set once at launch from `--config-dir` to point config/modes/history at a throwaway directory,
    // so dev runs can exercise onboarding without touching the real configuration.
    nonisolated(unsafe) static var configDirOverride: URL?

    static var variant: AppVariant {
        AppVariant(
            bundleID: Bundle.main.bundleIdentifier,
            bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    private static var appSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // Per-variant: the KeyScribeDev build keeps its own config/modes/history under "KeyScribeDev/" so
    // it never collides with the installed production app's configuration.
    private static var defaultSupportDir: URL {
        appSupportBase.appendingPathComponent(variant.supportFolderName, isDirectory: true)
    }

    static var supportDir: URL {
        configDirOverride ?? defaultSupportDir
    }

    // Downloaded weights are a large shared cache: pinned to the production folder for every variant
    // (and never redirected by `--config-dir`), so a dev or sandbox run reuses the real models instead
    // of re-downloading multiple gigabytes.
    static var modelsDir: URL {
        appSupportBase
            .appendingPathComponent(AppVariant.sharedModelsFolderName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    static var modesDir: URL {
        supportDir.appendingPathComponent("modes", isDirectory: true)
    }
}
