import Foundation
import KeyScribeKit
import os

// In-memory cache of the on-disk config. Loaded lazily and invalidated on demand (ConfigWatcher on file
// change, or the Settings reload button) — so a normal dictation does zero config I/O while edits still
// apply on the next dictation. (settings.toml stays owned by AppDelegate / Settings UI.)
@MainActor
final class ConfigCache {
    private let supportDir: URL
    private let log = Logger(subsystem: "com.keyscribe.app", category: "config")

    // Survives invalidate(): the last successfully-loaded config, so a mid-edit malformed file falls back to
    // its prior good copy instead of disappearing (§5.1). A clean file AND an absent file both update it
    // (absent → empty default), so a delete then a malformed write can't resurrect the pre-delete copy.
    private var lastGoodModes: [Mode] = []
    private var lastGoodReplacements = ReplacementsSet()
    private var lastGoodConnections = ConnectionSet()
    private var lastGoodDictionary = DictionarySet()

    private var modesCache: [Mode]?
    private var replacementsCache: ReplacementsSet?
    private var connectionsCache: ConnectionSet?
    private var dictionaryCache: DictionarySet?
    private var resolvedCache: ResolvedConfig?

    // Per generation: present-but-undecodable files (malformed or newer schema after a downgrade). Recorded
    // so a fat-fingered replacements.toml lights the same user-visible malformed-config warning as
    // settings.toml instead of silently disabling every replacement / connection. Reset by invalidate().
    private(set) var loadFailures: [String] = []

    init(supportDir: URL) {
        self.supportDir = supportDir
    }

    func invalidate() {
        modesCache = nil
        replacementsCache = nil
        connectionsCache = nil
        dictionaryCache = nil
        resolvedCache = nil
        loadFailures = []
    }

    // User-facing summary of any config file that failed to decode this generation, or nil if all loaded
    // (or absent). Forces the vocabulary/connection loads so the answer is complete regardless of call order.
    var configFileError: String? {
        _ = dictionary; _ = replacements; _ = connections; _ = modes
        return loadFailures.isEmpty ? nil : loadFailures.joined(separator: "; ")
    }

    private func recordLoadFailure(_ fileName: String, _ error: ConfigError) {
        let message = "\(fileName) — \(Self.describe(error))"
        if !loadFailures.contains(message) { loadFailures.append(message) }
        log.error("config '\(fileName, privacy: .public)' failed to load: \(Self.describe(error), privacy: .public)")
    }

    private static func describe(_ error: ConfigError) -> String {
        switch error {
        case .missingSchemaVersion: "missing schema_version"
        case .newerSchemaVersion(let found, let supported):
            "schema \(found) is newer than this build supports (\(supported))"
        case .invalid(let message): message
        }
    }

    // Frozen derived view handed to a dictation at record-start (captured once so a mid-dictation reload
    // can't change what an in-flight dictation sees). Rebuilt only on invalidate, else reused, so the
    // per-mode merged dictionary and compiled stages are computed at most once.
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

    // Disk-backed last-known-good for modes, OUTSIDE the watched modes/ dir so a recovery copy is never read
    // as a real mode and the launch case (malformed before any in-memory good exists) is still recoverable.
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
            let recovery = failure.usedLastKnownGood ? " (kept last-known-good)" : " (skipped)"
            log.error("mode '\(failure.id, privacy: .public)' failed to load\(recovery, privacy: .public): \(failure.message, privacy: .public)")
            let message = "\(failure.id).toml — \(failure.message)\(recovery)"
            if !loadFailures.contains(message) { loadFailures.append(message) }
        }
        modesCache = result.modes
        lastGoodModes = result.modes
        return result.modes
    }

    var replacements: ReplacementsSet {
        if let replacementsCache { return replacementsCache }
        let loaded: ReplacementsSet
        switch ReplacementsStore.load(supportDir: supportDir) {
        case .absent: loaded = ReplacementsSet(); lastGoodReplacements = ReplacementsSet()
        case .loaded(let set): loaded = set; lastGoodReplacements = set
        case .failed(let error): loaded = lastGoodReplacements; recordLoadFailure(ReplacementsStore.fileName, error)
        }
        replacementsCache = loaded
        return loaded
    }

    var connections: ConnectionSet {
        if let connectionsCache { return connectionsCache }
        let loaded: ConnectionSet
        switch ConnectionStore.load(supportDir: supportDir) {
        case .absent: loaded = ConnectionSet(); lastGoodConnections = ConnectionSet()
        case .loaded(let set): loaded = set; lastGoodConnections = set
        case .failed(let error): loaded = lastGoodConnections; recordLoadFailure(ConnectionStore.fileName, error)
        }
        connectionsCache = loaded
        return loaded
    }

    var dictionary: DictionarySet {
        if let dictionaryCache { return dictionaryCache }
        let loaded: DictionarySet
        switch DictionaryStore.load(supportDir: supportDir) {
        case .absent: loaded = DictionarySet(); lastGoodDictionary = DictionarySet()
        case .loaded(let set): loaded = set; lastGoodDictionary = set
        case .failed(let error): loaded = lastGoodDictionary; recordLoadFailure(DictionaryStore.fileName, error)
        }
        dictionaryCache = loaded
        return loaded
    }
}
