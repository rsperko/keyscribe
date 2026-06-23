import Foundation
import KeyScribeKit

// Tracks which downloadable engines are installed via a small marker file, decoupled from each SDK's
// on-disk layout. The active engine and rules live in KeyScribeKit's SpeechModelSet; this is durable
// install bookkeeping plus best-effort file removal. Per-engine footprint/integrity now lives on the
// engines themselves (installDirNames / verifyInstalled), so this stays generic — no hardcoded dir maps.
enum ModelInstallStore {
    private static var markerURL: URL {
        KeyScribePaths.modelsDir.appendingPathComponent(markerFile)
    }

    private static let markerFile = "installed.json"

    // Reconcile the marker against disk: adopt completed-but-unrecorded downloads, drop entries whose
    // files are gone/partial, and delete orphaned directories. Each engine reports what it owns and
    // whether it's present (Parakeet verifies; others defer to the marker). System-managed engines
    // have no install footprint and are skipped. Run at launch with the constructed engine set.
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
            dirsOnDisk: directoriesOnDisk(), keep: [markerFile])
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

    static func installedIds() -> Set<String> {
        guard let data = try? Data(contentsOf: markerURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
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
        } catch {
            // A lost marker isn't fatal — reconcile re-derives install state from disk next launch — but
            // it can mean a re-download, so surface it rather than swallow it.
            Log.models.error("install marker write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // On-disk install directories for an engine that actually exist (for reveal + size display).
    static func presentInstallURLs(for id: String) -> [URL] {
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
