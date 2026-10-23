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
    // its prior good copy instead of disappearing (§5.1). nil until a file loads, and reset to nil when it is
    // absent, so a delete then a malformed write can't resurrect the pre-delete copy and a failure with
    // nothing to fall back on is reported as such.
    private var lastGoodModes: [Mode] = []
    private var lastGoodReplacements: ReplacementsSet?
    private var lastGoodConnections: ConnectionSet?
    private var lastGoodDictionary: DictionarySet?
    private var lastGoodVoiceCommands: VoiceCommandConfig?

    private var modesCache: [Mode]?
    private var voiceCommandsShutOutCache = false
    private var replacementsCache: ReplacementsSet?
    private var connectionsCache: ConnectionSet?
    private var dictionaryCache: DictionarySet?
    private var voiceCommandsCache: VoiceCommandConfig?
    private var resolvedCache: ResolvedConfig?

    // Per generation: present-but-undecodable files (malformed or newer schema after a downgrade). Recorded
    // so a fat-fingered replacements.toml lights the same user-visible malformed-config warning as
    // settings.toml instead of silently disabling every replacement / connection. Reset by invalidate().
    private(set) var loadFailures: [ConfigFileIssue] = []
    private var fileWarningsCache: [ConfigFileIssue]?

    var voiceCommandsEnabled = false {
        didSet { if voiceCommandsEnabled != oldValue { invalidate() } }
    }

    init(supportDir: URL) {
        self.supportDir = supportDir
    }

    func invalidate() {
        modesCache = nil
        replacementsCache = nil
        connectionsCache = nil
        dictionaryCache = nil
        voiceCommandsCache = nil
        resolvedCache = nil
        loadFailures = []
        fileWarningsCache = nil
    }

    // User-facing summary of any config file that failed to decode this generation, or nil if all loaded
    // (or absent). Forces the vocabulary/connection loads so the answer is complete regardless of call order.
    var configFileError: String? {
        let failures = fileFailures
        return failures.isEmpty ? nil : failures.map(\.oneLine).joined(separator: "; ")
    }

    var fileFailures: [ConfigFileIssue] {
        _ = dictionary; _ = replacements; _ = connections; _ = modes
        if voiceCommandsEnabled { _ = voiceCommands }
        return loadFailures
    }

    // Keys a file carries that nothing reads, so editing them silently does nothing. Computed on demand
    // (status refresh, Settings), never on the dictation path.
    var fileWarnings: [ConfigFileIssue] {
        if let fileWarningsCache { return fileWarningsCache }
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        let modeFiles = ((try? FileManager.default.contentsOfDirectory(atPath: modesDir.path)) ?? [])
            .filter { $0.hasSuffix(".toml") }
            .sorted()
        let warnings = ([
            warning(SettingsStore.fileName, in: supportDir, SettingsStore.unknownKeys(in:)),
            warning(DictionaryStore.fileName, in: supportDir, DictionaryStore.unknownKeys(in:)),
            warning(ReplacementsStore.fileName, in: supportDir, ReplacementsStore.unknownKeys(in:)),
            warning(ConnectionStore.fileName, in: supportDir, ConnectionStore.unknownKeys(in:)),
            voiceCommandsEnabled
                ? warning(VoiceCommandStore.fileName, in: supportDir, VoiceCommandStore.unknownKeys(in:)) : nil,
        ] + modeFiles.map { warning($0, in: modesDir, ModeStore.unknownKeys(in:)) }).compactMap { $0 }
        fileWarningsCache = warnings
        return warnings
    }

    private func warning(
        _ fileName: String, in dir: URL, _ unknownKeys: (String) -> [UnknownConfigKey]
    ) -> ConfigFileIssue? {
        let url = dir.appendingPathComponent(fileName)
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let keys = unknownKeys(toml)
        guard !keys.isEmpty else { return nil }
        return .unusedKeys(fileName, relativePath: relativePath(of: url), keys)
    }

    private func relativePath(of url: URL) -> String {
        String(url.path.dropFirst(supportDir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func recordLoadFailure(_ fileName: String, _ error: ConfigError, keptPrevious: Bool) {
        let issue = ConfigFileIssue.unreadable(
            fileName, error: error, recovery: keptPrevious ? .previousVersion : .ignored)
        if !loadFailures.contains(issue) { loadFailures.append(issue) }
        log.error("config '\(fileName, privacy: .public)' failed to load (\(error.category, privacy: .public)): \(error.summary, privacy: .private)")
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

    // Realizes this generation's plan now, and compiles each enabled mode's text stages and bias terms off
    // the main actor, so the first press after launch or a config change reads no fragments and compiles no
    // replacement regexes on the hot path.
    @discardableResult
    func prewarm() -> Task<Void, Never> {
        let plan = resolved
        return Task.detached(priority: .utility) {
            for mode in plan.modes where mode.enabled {
                _ = plan.postSTTTextStages(for: mode)
                _ = plan.recognitionBiasTerms(for: mode)
            }
        }
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
            let recovery = failure.usedLastKnownGood ? " — previous version still in use" : " — ignored until fixed"
            log.error("mode '\(failure.id, privacy: .public)' failed to load\(recovery, privacy: .public) (\(failure.error.category, privacy: .public)): \(failure.message, privacy: .private)")
            let issue = ConfigFileIssue.unreadable(
                "\(failure.id).toml", relativePath: "modes/\(failure.id).toml",
                error: failure.error, recovery: failure.usedLastKnownGood ? .previousVersion : .ignored)
            if !loadFailures.contains(issue) { loadFailures.append(issue) }
        }
        let unguarded = Mode.visible(result.modes, voiceCommands: voiceCommandsEnabled)
        let visible = VoiceCommandTriggers.guarded(unguarded)
        voiceCommandsShutOutCache = VoiceCommandTriggers.isShutOut(unguarded)
        modesCache = visible
        lastGoodModes = result.modes
        return visible
    }

    // Every mode on disk, including one a feature flag hides, for bookkeeping that must outlive the flag.
    var storedModes: [Mode] {
        _ = modes
        return lastGoodModes
    }

    var voiceCommandsShutOut: Bool {
        _ = modes
        return voiceCommandsShutOutCache
    }

    var voiceCommands: VoiceCommandConfig {
        if let voiceCommandsCache { return voiceCommandsCache }
        let loaded: VoiceCommandConfig
        switch VoiceCommandStore.load(supportDir: supportDir) {
        case .absent: loaded = VoiceCommandConfig(); lastGoodVoiceCommands = nil
        case .loaded(let config): loaded = config; lastGoodVoiceCommands = config
        case .failed(let error):
            loaded = lastGoodVoiceCommands ?? VoiceCommandConfig()
            recordLoadFailure(VoiceCommandStore.fileName, error, keptPrevious: lastGoodVoiceCommands != nil)
        }
        voiceCommandsCache = loaded
        return loaded
    }

    var replacements: ReplacementsSet {
        if let replacementsCache { return replacementsCache }
        let loaded: ReplacementsSet
        switch ReplacementsStore.load(supportDir: supportDir) {
        case .absent: loaded = ReplacementsSet(); lastGoodReplacements = nil
        case .loaded(let set): loaded = set; lastGoodReplacements = set
        case .failed(let error):
            loaded = lastGoodReplacements ?? ReplacementsSet()
            recordLoadFailure(ReplacementsStore.fileName, error, keptPrevious: lastGoodReplacements != nil)
        }
        replacementsCache = loaded
        return loaded
    }

    var connections: ConnectionSet {
        if let connectionsCache { return connectionsCache }
        let loaded: ConnectionSet
        switch ConnectionStore.load(supportDir: supportDir) {
        case .absent: loaded = ConnectionSet(); lastGoodConnections = nil
        case .loaded(let set): loaded = set; lastGoodConnections = set
        case .failed(let error):
            loaded = lastGoodConnections ?? ConnectionSet()
            recordLoadFailure(ConnectionStore.fileName, error, keptPrevious: lastGoodConnections != nil)
        }
        connectionsCache = loaded
        return loaded
    }

    var dictionary: DictionarySet {
        if let dictionaryCache { return dictionaryCache }
        let loaded: DictionarySet
        switch DictionaryStore.load(supportDir: supportDir) {
        case .absent: loaded = DictionarySet(); lastGoodDictionary = nil
        case .loaded(let set): loaded = set; lastGoodDictionary = set
        case .failed(let error):
            loaded = lastGoodDictionary ?? DictionarySet()
            recordLoadFailure(DictionaryStore.fileName, error, keptPrevious: lastGoodDictionary != nil)
        }
        dictionaryCache = loaded
        return loaded
    }
}
