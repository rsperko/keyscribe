import Foundation
import KeyScribeKit

enum KeyScribePaths {
    // Set once at launch from `--config-dir`: points config/modes/history at a throwaway directory so dev
    // runs can exercise onboarding without touching the real configuration.
    nonisolated(unsafe) static var configDirOverride: URL?

    static var variant: AppVariant {
        AppVariant(
            bundleID: Bundle.main.bundleIdentifier,
            bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    private static var appSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // Per-variant: the dev build keeps its own config/modes/history under "KeyScribeDev/" so it never
    // collides with the installed production app's configuration.
    private static var defaultSupportDir: URL {
        appSupportBase.appendingPathComponent(variant.supportFolderName, isDirectory: true)
    }

    static var supportDir: URL {
        configDirOverride ?? defaultSupportDir
    }

    // Downloaded weights are a large shared cache: pinned to the production folder for every variant (never
    // redirected by `--config-dir`), so a dev or sandbox run reuses the real models instead of re-downloading.
    static var modelsDir: URL {
        appSupportBase
            .appendingPathComponent(AppVariant.sharedModelsFolderName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    // The one creator of modelsDir. Exclusion only takes on an existing path, and an engine downloading into
    // a subdir can recreate modelsDir without it, so this re-applies on every call rather than setting once.
    @discardableResult
    static func ensureModelsDir() -> URL {
        let dir = modelsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupExclusion.exclude(dir)
        return dir
    }

    // Runtime marker of global system audio state to restore after a crash. Lives as a sibling FILE of
    // supportDir, NOT inside the FSEvents-watched config tree, so per-dictation record/clear writes don't
    // fire ConfigWatcher. Keyed by variant but never redirected by `--config-dir` — it is real system state,
    // so a normal launch must still find a throwaway run's marker to recover.
    static var pendingSystemRestoreFile: URL {
        appSupportBase.appendingPathComponent(
            "\(variant.supportFolderName)-pending-system-restore.json", isDirectory: false)
    }

    // Durable record of STT model-load failures. Diagnostics, not user config — a sibling FILE of supportDir
    // (not inside the FSEvents-watched tree, so a write here can't fire ConfigWatcher). Keyed by variant.
    static var modelLoadDiagFile: URL {
        appSupportBase.appendingPathComponent(
            "\(variant.supportFolderName)-model-load-diagnostics.log", isDirectory: false)
    }

    // Retained capture WAVs (`[audio] keep_captures`). A sibling DIRECTORY of supportDir, deliberately
    // outside the FSEvents-watched config tree — ConfigTreeSnapshot stat-stamps every file it finds, so a
    // WAV landing inside would fire a full config reload after every dictation. Keyed by variant, so the dev
    // build archives on its own; never redirected by `--config-dir` (diagnostics, not user config).
    static var captureArchiveDir: URL {
        appSupportBase.appendingPathComponent("\(variant.supportFolderName)-captures", isDirectory: true)
    }

    static var modesDir: URL {
        supportDir.appendingPathComponent("modes", isDirectory: true)
    }

    static var lkgDir: URL {
        supportDir.appendingPathComponent("lkg", isDirectory: true)
    }
}
