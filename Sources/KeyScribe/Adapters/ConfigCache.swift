import Foundation
import KeyScribeKit

// In-memory cache of the on-disk config. Loaded lazily on first access and invalidated on demand
// (by the ConfigWatcher when files change, or the Settings reload button) — so a normal dictation
// does zero config I/O, while edits still apply on the next dictation. (settings.toml stays owned
// by AppDelegate / Settings UI.)
@MainActor
final class ConfigCache {
    private let supportDir: URL

    private var modesCache: [Mode]?
    private var replacementsCache: ReplacementsSet?
    private var connectionsCache: ConnectionSet?
    private var dictionaryCache: DictionarySet?
    private var fragmentCache: [String: String] = [:]

    init(supportDir: URL) {
        self.supportDir = supportDir
    }

    func invalidate() {
        modesCache = nil
        replacementsCache = nil
        connectionsCache = nil
        dictionaryCache = nil
        fragmentCache = [:]
    }

    var modes: [Mode] {
        if let modesCache { return modesCache }
        let loaded = ModeStore.loadAll(in: supportDir.appendingPathComponent("modes", isDirectory: true))
        modesCache = loaded
        return loaded
    }

    var replacements: ReplacementsSet {
        if let replacementsCache { return replacementsCache }
        let loaded = ReplacementsStore.loadOrDefault(supportDir: supportDir)
        replacementsCache = loaded
        return loaded
    }

    var connections: ConnectionSet {
        if let connectionsCache { return connectionsCache }
        let loaded = ConnectionStore.loadOrDefault(supportDir: supportDir)
        connectionsCache = loaded
        return loaded
    }

    var dictionary: DictionarySet {
        if let dictionaryCache { return dictionaryCache }
        let loaded = DictionaryStore.loadOrDefault(supportDir: supportDir)
        dictionaryCache = loaded
        return loaded
    }

    func fragmentBodies(ids: [String]) -> [String] {
        let dir = supportDir.appendingPathComponent("fragments", isDirectory: true)
        return ids.compactMap { id in
            if let cached = fragmentCache[id] { return cached.isEmpty ? nil : cached }
            let body = FragmentStore.load(ids: [id], from: dir).first ?? ""
            fragmentCache[id] = body
            return body.isEmpty ? nil : body
        }
    }
}
