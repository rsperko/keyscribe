import Foundation
import KeyScribeKit

// Durable install bookkeeping for downloadable engines, independent of each SDK's directory layout.
enum ModelInstallStore {
    private static var markerURL: URL {
        KeyScribePaths.modelsDir.appendingPathComponent(markerFile)
    }

    private static let markerFile = "installed.json"

    // The marker set is read on every dictation press but only ever written by this process, so cache it in
    // memory (refreshed by `write`). Lock-guarded: reads run on the main actor, writes can run off it.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedIds: Set<String>?

    // Reconcile the marker against disk and remove orphaned directories.
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

        let plan = ModelMaintenance.reconcile(
            knownIds: Array(owned.keys), owned: owned, completeIds: complete,
            dirsOnDisk: directoriesOnDisk(), markedIds: marked,
            protectedDirs: recentlyModifiedDirs(), keep: [markerFile])
        let adopted = plan.installed.subtracting(marked)
        let dropped = marked.subtracting(plan.installed)
        Log.models.notice("reconcile: installed=\(plan.installed.sorted(), privacy: .public) adopted=\(adopted.sorted(), privacy: .public) dropped=\(dropped.sorted(), privacy: .public) orphanDirs=\(plan.removeDirs.sorted(), privacy: .public)")
        write(plan.installed)

        guard !plan.removeDirs.isEmpty else { return }
        let dirs = plan.removeDirs
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

    private static func recentlyModifiedDirs() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: KeyScribePaths.modelsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let cutoff = Date().addingTimeInterval(-downloadRecencyWindow)
        var recent: Set<String> = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if directoryActive(entry, since: cutoff) { recent.insert(entry.lastPathComponent) }
        }
        return recent
    }

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
        // A write may have landed a newer value while we read disk unlocked; don't clobber it with the
        // stale first read. Adopt our read only if the cache is still empty.
        cacheLock.lock()
        if cachedIds == nil { cachedIds = ids }
        let result = cachedIds ?? ids
        cacheLock.unlock()
        return result
    }

    static func markInstalled(_ id: String) {
        var ids = installedIds()
        ids.insert(id)
        write(ids)
        Log.models.notice("marked installed: \(id, privacy: .public)")
    }

    static func markRemoved(_ id: String) {
        var ids = installedIds()
        ids.remove(id)
        write(ids)
        Log.models.notice("marked removed: \(id, privacy: .public)")
    }

    static func removeFiles(for id: String) {
        guard let engine = EngineRegistry.engine(id, modelsDir: KeyScribePaths.modelsDir) else {
            Log.models.error("removeFiles: no engine for \(id, privacy: .public)")
            return
        }
        Log.models.notice("removing files for \(id, privacy: .public): \(engine.installDirNames, privacy: .public)")
        for name in engine.installDirNames {
            try? FileManager.default.removeItem(
                at: KeyScribePaths.modelsDir.appendingPathComponent(name))
        }
    }

    private static func write(_ ids: Set<String>) {
        do {
            try FileManager.default.createDirectory(
                at: KeyScribePaths.modelsDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(ids.sorted()).write(to: markerURL, options: .atomic)
            // Update the cache only after the durable write succeeds, so a failed write never leaves the
            // process believing an install/removal happened.
            cacheLock.lock()
            cachedIds = ids
            cacheLock.unlock()
        } catch {
            Log.models.error("install marker write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // On-disk install directories for an engine that actually exist.
    private static func presentInstallURLs(for id: String) -> [URL] {
        guard let engine = EngineRegistry.engine(id, modelsDir: KeyScribePaths.modelsDir) else { return [] }
        let fm = FileManager.default
        return engine.installDirNames
            .map { KeyScribePaths.modelsDir.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    // Actual bytes on disk across an engine's install directories; nil when nothing is present.
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
