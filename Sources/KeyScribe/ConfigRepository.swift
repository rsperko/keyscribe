import Foundation
import KeyScribeKit

// The single owner of on-disk config writes (dictionary, replacements, modes, connections). Every mutation
// is a fresh read-modify-write from disk (so a concurrent write from another surface — the global
// Add-to-Vocabulary hotkey while a Settings pane is open — is never clobbered by stale in-memory state),
// then invalidates the ConfigCache immediately so the next dictation sees the change without waiting on the
// FSEvents watcher. The watcher stays only as a backstop for external edits (an extra invalidate is
// idempotent). `onChange` lets the host refresh dependent UI (menu status).
//
// Mutators THROW so a Settings pane can surface the failure; the `add*` helpers wrap them into a Bool for
// correction-surface callers (menu, History detail, correction panel) that only care whether it stuck.
// settings.toml is NOT owned here — it is a whole-object write routed through AppDelegate.applySettings
// (external edits absorbed only via the FSEvents reload path); read-modify-write would buy little there.
@MainActor
final class ConfigRepository {
    let supportDir: URL
    private let config: ConfigCache
    private let selfWriteGate: ConfigSelfWriteGate
    var onChange: (() -> Void)?
    // In-app observers (beyond the host's `onChange`) that re-read from disk when any surface writes config —
    // notably the Settings pane models, whose drafts would otherwise clobber a term the correction panel
    // routed into a mode while the pane was open.
    private var changeObservers: [() -> Void] = []

    init(supportDir: URL, config: ConfigCache, selfWriteGate: ConfigSelfWriteGate = ConfigSelfWriteGate()) {
        self.supportDir = supportDir
        self.config = config
        self.selfWriteGate = selfWriteGate
    }

    func addChangeObserver(_ observer: @escaping () -> Void) {
        changeObservers.append(observer)
    }

    // For the FSEvents external-edit reload path (AppDelegate.reloadConfig), which performs the host's
    // `onChange` effects itself: refresh only the in-app observers so an open Settings pane re-reads a
    // file edited outside the app.
    func notifyExternalChange() {
        for observer in changeObservers { observer() }
    }

    private func notifyChange() {
        onChange?()
        for observer in changeObservers { observer() }
    }

    // For write paths not routed through `commit` (fragment files edited directly by ModesSettingsView).
    // Matches `commit`'s post-write discipline: suppress the watcher echo, invalidate the cache so the next
    // dictation sees the edited instruction (fragments are baked into the resolved plan and reused across
    // dictations — without this an AI-rewrite instruction edit does nothing until relaunch), then notify.
    func recordSelfWrite(at url: URL) {
        selfWriteGate.recordSelfWrite(url: url, supportDir: supportDir)
        config.invalidate()
        notifyChange()
    }

    var modesDir: URL { supportDir.appendingPathComponent("modes", isDirectory: true) }

    func dictionaryWords() -> [String] { DictionaryStore.loadOrDefault(supportDir: supportDir).words }
    func replacementRules() -> [ReplacementsSet.Rule] { ReplacementsStore.loadOrDefault(supportDir: supportDir).rules }

    @discardableResult
    func addDictionaryWord(_ word: String) -> Bool {
        (try? mutateDictionary { $0.adding(word: word) }) != nil
    }

    @discardableResult
    func addDictionaryWord(_ word: String, toMode modeId: String) -> Bool {
        (try? mutateMode(id: modeId) { mode in
            let set = DictionarySet(words: mode.dictionary.words).adding(word: word)
            mode.dictionary.words = set.words
        }) != nil
    }

    @discardableResult
    func mutateDictionary(_ transform: (DictionarySet) -> DictionarySet) throws -> DictionarySet {
        let updated = transform(try loadDictionaryForMutation())
        try commit(touching: [supportDir.appendingPathComponent(DictionaryStore.fileName)]) {
            try DictionaryStore.write(updated, to: supportDir)
        }
        return updated
    }

    @discardableResult
    func addReplacement(heard: String, replace: String, regex: Bool = false) -> Bool {
        let result = try? mutateReplacements { set in
            set = set.adding(heard: heard, replace: replace, regex: regex)
        }
        return result != nil
    }

    @discardableResult
    func addReplacement(heard: String, replace: String, regex: Bool = false, toMode modeId: String) -> Bool {
        let result = try? mutateMode(id: modeId) { mode in
            let set = ReplacementsSet(rules: mode.replacements.rules)
                .adding(heard: heard, replace: replace, regex: regex)
            mode.replacements.rules = set.rules
        }
        return result != nil
    }

    @discardableResult
    func mutateReplacements(_ transform: (inout ReplacementsSet) -> Void) throws -> ReplacementsSet {
        var set = try loadReplacementsForMutation()
        transform(&set)
        try commit(touching: [supportDir.appendingPathComponent(ReplacementsStore.fileName)]) {
            try ReplacementsStore.write(set, to: supportDir)
        }
        return set
    }

    func writeMode(_ mode: Mode) throws {
        try commit(touching: [modeFileURL(id: mode.id)]) { try ModeStore.write(mode, to: modesDir) }
    }

    @discardableResult
    func mutateMode(id: String, _ transform: (inout Mode) -> Void) throws -> Mode {
        var mode = try loadModeForMutation(id: id)
        guard !mode.isSystem else { throw ConfigError.invalid("system modes cannot hold local vocabulary") }
        transform(&mode)
        try writeMode(mode)
        return mode
    }

    func deleteMode(_ mode: Mode) throws {
        try commit(touching: [modeFileURL(id: mode.id)]) {
            try ModeStore.delete(mode, from: modesDir)
            try? FileManager.default.removeItem(
                at: supportDir.appendingPathComponent("lkg/modes", isDirectory: true)
                    .appendingPathComponent("\(mode.id).toml"))
        }
    }

    // Re-slug a mode's file (id is the filename stem). Write the new file, then delete the old; if the delete
    // fails, roll the new file back so a failed rename can never leave a DUPLICATE mode on disk (original
    // untouched, error surfaced). Invalidates once, not twice.
    func renameMode(_ mode: Mode, to newId: String) throws {
        guard newId != mode.id else { return }
        guard !mode.isSystem else { throw ConfigError.invalid("system modes cannot be renamed") }
        let fm = FileManager.default
        let destination = modesDir.appendingPathComponent("\(newId).toml")
        if fm.fileExists(atPath: destination.path) {
            throw ConfigError.invalid("mode id already exists")
        }
        var renamed = mode
        renamed.id = newId
        try commit(touching: [modeFileURL(id: newId), modeFileURL(id: mode.id)]) {
            try ModeStore.write(renamed, to: modesDir)
            do {
                try ModeStore.delete(mode, from: modesDir)
            } catch {
                if !Self.isMissingFile(error) {
                    try? ModeStore.delete(renamed, from: modesDir)
                    throw error
                }
            }
        }
    }

    // Read-modify-write insert-or-replace by id, so a connection written by another surface (first-run, a
    // concurrent pane) between this model's snapshot and its save is never clobbered. Returns the fresh set.
    @discardableResult
    func upsertConnection(_ connection: Connection) throws -> ConnectionSet {
        try mutateConnections { set in
            if let i = set.connections.firstIndex(where: { $0.id == connection.id }) {
                set.connections[i] = connection
            } else {
                set.connections.append(connection)
            }
        }
    }

    @discardableResult
    func deleteConnection(id: String) throws -> ConnectionSet {
        try mutateConnections { set in set.connections.removeAll { $0.id == id } }
    }

    @discardableResult
    func mutateConnections(_ transform: (inout ConnectionSet) -> Void) throws -> ConnectionSet {
        var set = try loadConnectionsForMutation()
        transform(&set)
        try commit(touching: [supportDir.appendingPathComponent(ConnectionStore.fileName)]) {
            try ConnectionStore.write(set, to: supportDir)
        }
        return set
    }

    // On write success: record the touched files (suppress the watcher echo), invalidate the cache, then
    // notify. On a throw nothing is invalidated (on-disk state unchanged) and the error propagates.
    private func commit(touching paths: [URL], _ write: () throws -> Void) throws {
        try write()
        for path in paths { selfWriteGate.recordSelfWrite(url: path, supportDir: supportDir) }
        config.invalidate()
        notifyChange()
    }

    private func modeFileURL(id: String) -> URL { modesDir.appendingPathComponent("\(id).toml") }

    private func loadDictionaryForMutation() throws -> DictionarySet {
        let file = supportDir.appendingPathComponent(DictionaryStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return DictionarySet() }
        return try DictionaryStore.decode(from: String(contentsOf: file, encoding: .utf8))
    }

    private func loadReplacementsForMutation() throws -> ReplacementsSet {
        let file = supportDir.appendingPathComponent(ReplacementsStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return ReplacementsSet() }
        return try ReplacementsStore.decode(from: String(contentsOf: file, encoding: .utf8))
    }

    private func loadModeForMutation(id: String) throws -> Mode {
        let file = modeFileURL(id: id)
        return try ModeStore.decode(from: String(contentsOf: file, encoding: .utf8), id: id)
    }

    private func loadConnectionsForMutation() throws -> ConnectionSet {
        let file = supportDir.appendingPathComponent(ConnectionStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return ConnectionSet() }
        return try ConnectionStore.decode(from: String(contentsOf: file, encoding: .utf8))
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError
    }
}
