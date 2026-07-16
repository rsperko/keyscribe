import Foundation
import KeyScribeKit

// Durable record of models that failed their self-test, so the "failed" indicator and quarantine survive a
// relaunch. Sibling to ModelInstallStore: installed.json says a model is on disk; model-health.json says a
// model on disk can't transcribe and must not be used until it passes a re-test. Kept separate so the install
// marker never has to encode health and reconcile stays a pure on-disk check.
enum ModelHealthStore {
    private static let markerFile = "model-health.json"
    private static var markerURL: URL {
        KeyScribePaths.modelsDir.appendingPathComponent(markerFile)
    }

    // Read on every dictation press (via InstalledEngineFilter), written only by this process → cache in
    // memory, refreshed by `write`. Lock-guarded: reads on the main actor, writes can run off it.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedIds: Set<String>?

    static func failedIds() -> Set<String> {
        cacheLock.lock()
        if let cachedIds { cacheLock.unlock(); return cachedIds }
        cacheLock.unlock()
        let ids: Set<String>
        if let data = try? Data(contentsOf: markerURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = Set(decoded)
        } else {
            ids = []
        }
        // A write may have landed a newer value while we read disk unlocked; adopt our read only if the cache
        // is still empty, so we don't clobber it with the stale first read.
        cacheLock.lock()
        if cachedIds == nil { cachedIds = ids }
        let result = cachedIds ?? ids
        cacheLock.unlock()
        return result
    }

    static func markFailed(_ id: String) {
        var ids = failedIds()
        guard !ids.contains(id) else { return }
        ids.insert(id)
        write(ids)
        Log.models.notice("marked failed: \(id, privacy: .public)")
    }

    static func clearFailed(_ id: String) {
        var ids = failedIds()
        guard ids.contains(id) else { return }
        ids.remove(id)
        write(ids)
        Log.models.notice("cleared failed: \(id, privacy: .public)")
    }

    private static func write(_ ids: Set<String>) {
        do {
            KeyScribePaths.ensureModelsDir()
            try JSONEncoder().encode(ids.sorted()).write(to: markerURL, options: .atomic)
            // Update the cache only after the durable write succeeds, so a failed write never leaves the
            // process believing a health change happened.
            cacheLock.lock()
            cachedIds = ids
            cacheLock.unlock()
        } catch {
            Log.models.error("health marker write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
