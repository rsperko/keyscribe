import FluidAudio
import Foundation
import KeyScribeKit

enum ModelInstallStore {
    // One-shot cleanup of the retired Parakeet CTC 0.6B bias companion: the CTC-WS spotter that used it
    // was removed, so it's stranded on old installs and `reconcile` won't touch it (models/ is shared
    // across variants, so it preserves dirs no engine claims). Excludes parakeet-ctc-110m-coreml, which
    // the tdt-ctc-110m load path re-downloads as its CTC head on every load — deleting it would only churn.
    // Idempotent (missing dir = no-op), so safe to run every launch.
    static var retiredCtcCompanionDirNames: [String] {
        [CtcModelVariant.ctc06b].map {
            CtcModels.defaultCacheDirectory(for: $0).lastPathComponent
        }
    }

    static func deleteRetiredCtcCompanions() {
        let names = retiredCtcCompanionDirNames
        var freed: [String] = []
        for name in names {
            let url = KeyScribePaths.modelsDir.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url); freed.append(name) }
            catch {
                Log.models.error(
                    "ctc cleanup: \(name, privacy: .public) delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !freed.isEmpty {
            Log.models.notice("removed retired Parakeet CTC bias companions: \(freed.sorted(), privacy: .public)")
        }
    }
    private static var markerURL: URL {
        KeyScribePaths.modelsDir.appendingPathComponent(markerFile)
    }

    private static let markerFile = "installed.json"

    // Read on every dictation press, written only by this process → cache in memory (refreshed by `write`).
    // Lock-guarded: reads on the main actor, writes can run off it.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedIds: Set<String>?

    static func reconcile(engines: [any SpeechEngine]) {
        let marked = installedIds()
        var owned: [String: [String]] = [:]
        var complete: Set<String> = []
        for engine in engines {
            guard let info = SpeechModelCatalog.entry(for: engine.id), !info.systemManaged else { continue }
            owned[engine.id] = engine.installDirNames
            switch engine.verifyInstalled(in: KeyScribePaths.modelsDir) {
            case .some(true): complete.insert(engine.id)
            case .some(false): break
            case nil: if marked.contains(engine.id) { complete.insert(engine.id) }
            }
        }

        // No protectedDirs: it only narrows removeDirs, and recency is checked below on the (usually empty)
        // candidate set instead of walking the multi-GB shared models tree every launch.
        let plan = ModelMaintenance.reconcile(
            knownIds: Array(owned.keys), owned: owned, completeIds: complete,
            dirsOnDisk: directoriesOnDisk(), markedIds: marked, keep: [markerFile, VADModel.dirName])
        let adopted = plan.installed.subtracting(marked)
        let dropped = marked.subtracting(plan.installed)
        do {
            try write(plan.installed)
        } catch {
            Log.models.error("reconcile marker write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Recency-check only the candidate dirs (usually none), so the steady state does no per-file stat.
        let cutoff = Date().addingTimeInterval(-downloadRecencyWindow)
        let dirs = plan.removeDirs.filter { name in
            !directoryActive(KeyScribePaths.modelsDir.appendingPathComponent(name), since: cutoff)
        }
        Log.models.notice("reconcile: installed=\(plan.installed.sorted(), privacy: .public) adopted=\(adopted.sorted(), privacy: .public) dropped=\(dropped.sorted(), privacy: .public) orphanDirs=\(dirs.sorted(), privacy: .public)")
        guard !dirs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for name in dirs {
                try? FileManager.default.removeItem(
                    at: KeyScribePaths.modelsDir.appendingPathComponent(name))
            }
        }
    }

    private static func directoriesOnDisk() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: KeyScribePaths.modelsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return Set(
            entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { $0.lastPathComponent })
    }

    // Recently touched dirs may be in-flight downloads from this app variant or another.
    private static let downloadRecencyWindow: TimeInterval = 5 * 60

    // Check descendants too; long downloads may update file mtimes without touching the parent dir.
    static func directoryActive(_ dir: URL, since cutoff: Date) -> Bool {
        let fm = FileManager.default
        if let modified = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified >= cutoff { return true }
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return false }
        for case let url as URL in enumerator {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= cutoff { return true }
        }
        return false
    }

    static func installedIds() -> Set<String> {
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
        // A write may have landed a newer value while we read disk unlocked; adopt our read only if the
        // cache is still empty, so we don't clobber it with the stale first read.
        cacheLock.lock()
        if cachedIds == nil { cachedIds = ids }
        let result = cachedIds ?? ids
        cacheLock.unlock()
        return result
    }

    static func markInstalled(_ id: String) throws {
        var ids = installedIds()
        ids.insert(id)
        try write(ids)
        Log.models.notice("marked installed: \(id, privacy: .public)")
    }

    static func markRemoved(_ id: String) throws {
        var ids = installedIds()
        ids.remove(id)
        try write(ids)
        Log.models.notice("marked removed: \(id, privacy: .public)")
    }

    static func removeFiles(for id: String) throws {
        guard let engine = EngineRegistry.engine(id, modelsDir: KeyScribePaths.modelsDir) else {
            Log.models.error("removeFiles: no engine for \(id, privacy: .public)")
            throw EngineUnavailable.notWired(id)
        }
        Log.models.notice("removing files for \(id, privacy: .public): \(engine.installDirNames, privacy: .public)")
        for name in engine.installDirNames {
            let url = KeyScribePaths.modelsDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func write(_ ids: Set<String>) throws {
        KeyScribePaths.ensureModelsDir()
        try JSONEncoder().encode(ids.sorted()).write(to: markerURL, options: .atomic)
        cacheLock.lock()
        cachedIds = ids
        cacheLock.unlock()
    }

    private static func presentInstallURLs(for id: String) -> [URL] {
        guard let engine = EngineRegistry.engine(id, modelsDir: KeyScribePaths.modelsDir) else { return [] }
        let fm = FileManager.default
        return engine.installDirNames
            .map { KeyScribePaths.modelsDir.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    // nil when the engine's install directories don't exist yet.
    static func installedBytes(for id: String) -> Int64? {
        let urls = presentInstallURLs(for: id)
        guard !urls.isEmpty else { return nil }
        return urls.reduce(0) { $0 + directorySize($1) }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
