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

    private var modesCache: [Mode]?
    private var replacementsCache: ReplacementsSet?
    private var connectionsCache: ConnectionSet?
    private var dictionaryCache: DictionarySet?
    private var resolvedCache: ResolvedConfig?

    init(supportDir: URL) {
        self.supportDir = supportDir
    }

    func invalidate() {
        modesCache = nil
        replacementsCache = nil
        connectionsCache = nil
        dictionaryCache = nil
        resolvedCache = nil
    }

    // The frozen, derived view of this config generation handed to a dictation at record-start
    // (DictationController captures it once so a mid-dictation reload can't change what an in-flight
    // dictation sees). Rebuilt only when the config is invalidated; reused across dictations
    // otherwise, so the per-mode merged dictionary and compiled stages are computed at most once.
    var resolved: ResolvedConfig {
        if let resolvedCache { return resolvedCache }
        let modes = self.modes
        let referencedFragmentIds = Set(modes.flatMap { $0.aiRewrite?.fragments ?? [] })
        let fragmentDir = supportDir.appendingPathComponent("fragments", isDirectory: true)
        var fragments: [String: String] = [:]
        for id in referencedFragmentIds {
            fragments[id] = FragmentStore.load(ids: [id], from: fragmentDir).first ?? ""
        }
        let resolved = ResolvedConfig(
            modes: modes, dictionary: dictionary, replacements: replacements,
            connections: connections, fragments: fragments)
        resolvedCache = resolved
        return resolved
    }

    // Disk-backed last-known-good for modes, OUTSIDE the watched modes/ dir so a recovery copy is never
    // read as a real mode and the launch case (a file already malformed before any in-memory good exists)
    // is still recoverable.
    private var lkgModesDir: URL {
        supportDir.appendingPathComponent("lkg", isDirectory: true)
            .appendingPathComponent("modes", isDirectory: true)
    }

    var modes: [Mode] {
        if let modesCache { return modesCache }
        let result = ModeStore.load(
            in: supportDir.appendingPathComponent("modes", isDirectory: true),
            previous: lastGoodModes, lkgDir: lkgModesDir)
        for failure in result.failures {
            log.error("mode '\(failure.id, privacy: .public)' failed to load\(failure.usedLastKnownGood ? " (kept last-known-good)" : " (skipped)", privacy: .public): \(failure.message, privacy: .public)")
        }
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
}
