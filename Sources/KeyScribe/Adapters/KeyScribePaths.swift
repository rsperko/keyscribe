import Foundation

enum KeyScribePaths {
    // Set once at launch from `--config-dir` to point config/modes/history at a throwaway directory,
    // so dev runs can exercise onboarding without touching the real configuration.
    nonisolated(unsafe) static var configDirOverride: URL?

    private static var defaultSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyScribe", isDirectory: true)
    }

    static var supportDir: URL {
        configDirOverride ?? defaultSupportDir
    }

    // Downloaded weights are a large shared cache, never redirected by `--config-dir` — a sandbox run
    // reuses the real models instead of re-downloading multiple gigabytes.
    static var modelsDir: URL {
        defaultSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    static var modesDir: URL {
        supportDir.appendingPathComponent("modes", isDirectory: true)
    }
}
