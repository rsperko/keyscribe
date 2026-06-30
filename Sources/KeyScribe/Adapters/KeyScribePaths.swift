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

    // A small runtime marker recording global system audio state we must put back after a crash. It must
    // persist across a crash but is NOT user config, so it lives as a sibling FILE of supportDir (directly
    // under Application Support), NOT inside the FSEvents-watched config tree — otherwise the per-dictation
    // record/clear writes would fire ConfigWatcher and trigger spurious config reloads. Keyed by variant
    // (dev vs prod isolation) but never redirected by `--config-dir`: it is about real system state, so a
    // normal launch must still find a throwaway run's marker to recover.
    static var pendingSystemRestoreFile: URL {
        appSupportBase.appendingPathComponent(
            "\(variant.supportFolderName)-pending-system-restore.json", isDirectory: false)
    }

    // Durable record of STT model-load failures. Like pendingSystemRestoreFile it is diagnostics, not
    // user config, so it lives as a sibling FILE of supportDir (not inside the FSEvents-watched config
    // tree — a write here must not fire ConfigWatcher). Keyed by variant so dev and prod stay isolated.
    static var modelLoadDiagFile: URL {
        appSupportBase.appendingPathComponent(
            "\(variant.supportFolderName)-model-load-diagnostics.log", isDirectory: false)
    }

    static var modesDir: URL {
        supportDir.appendingPathComponent("modes", isDirectory: true)
    }

    static var lkgDir: URL {
        supportDir.appendingPathComponent("lkg", isDirectory: true)
    }
}
