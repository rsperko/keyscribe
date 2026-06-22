import Foundation
import KeyScribeKit
import os

// In-memory cache of the on-disk config. Loaded lazily on first access and invalidated on demand
// (by the ConfigWatcher when files change, or the Settings reload button) — so a normal dictation
// does zero config I/O, while edits still apply on the next dictation. (settings.toml stays owned
// by AppDelegate / Settings UI.)
@MainActor
final class ConfigCache {
    private let supportDir: URL
    private let log = Logger(subsystem: "com.keyscribe.app", category: "config")

    // Survives invalidate(): the last set of modes that decoded cleanly, so a mid-edit malformed
    // file falls back to its prior good copy instead of disappearing (design discipline §5.1).
    private var lastGoodModes: [Mode] = []
    private(set) var modeLoadFailures: [ModeStore.LoadFailure] = []

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
        let result = ModeStore.load(
            in: supportDir.appendingPathComponent("modes", isDirectory: true), previous: lastGoodModes)
        for failure in result.failures {
            log.error("mode '\(failure.id, privacy: .public)' failed to load\(failure.usedLastKnownGood ? " (kept last-known-good)" : " (skipped)", privacy: .public): \(failure.message, privacy: .public)")
        }
        modeLoadFailures = result.failures
        modesCache = result.modes
        lastGoodModes = result.modes
        return result.modes
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
