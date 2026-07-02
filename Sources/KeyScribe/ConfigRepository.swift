import Foundation
import KeyScribeKit

// The single owner of on-disk config writes (dictionary, replacements, modes, connections). Every
// mutation is a fresh read-modify-write from disk (so a concurrent write from another surface — the
// global Add-to-Vocabulary hotkey while a Settings pane is open — is never clobbered by stale
// in-memory state), then it invalidates the ConfigCache IMMEDIATELY so the *next dictation* sees the
// change without waiting on the FSEvents watcher. The watcher stays only as a backstop for EXTERNAL
// edits; an extra invalidate from it is harmless (idempotent). `onChange` lets the host refresh
// dependent UI (menu status).
//
// The mutating methods THROW so a Settings pane can surface the specific failure; the `add*` helpers
// wrap them into a Bool for the correction-surface callers (menu, History detail, correction panel)
// that only care whether it stuck. settings.toml is the one config file NOT owned here — it is a
// single whole-object write routed through AppDelegate.applySettings (which merges against the
// on-disk value to avoid clobbering an external edit); folding a whole-struct rewrite behind
// read-modify-write would buy nothing.
@MainActor
final class ConfigRepository {
    let supportDir: URL
    private let config: ConfigCache
    var onChange: (() -> Void)?

    init(supportDir: URL, config: ConfigCache) {
        self.supportDir = supportDir
        self.config = config
    }

    var modesDir: URL { supportDir.appendingPathComponent("modes", isDirectory: true) }

    // MARK: Reads (the pane models render from these; every write returns the fresh value too)

    func dictionaryWords() -> [String] { DictionaryStore.loadOrDefault(supportDir: supportDir).words }
    func replacementRules() -> [ReplacementsSet.Rule] { ReplacementsStore.loadOrDefault(supportDir: supportDir).rules }

    // MARK: Dictionary

    @discardableResult
    func addDictionaryWord(_ word: String) -> Bool {
        (try? mutateDictionary { $0.adding(word: word) }) != nil
    }

    // Read-modify-write from disk, then invalidate + notify. Returns the written set.
    @discardableResult
    func mutateDictionary(_ transform: (DictionarySet) -> DictionarySet) throws -> DictionarySet {
        let updated = transform(try loadDictionaryForMutation())
        try commit { try DictionaryStore.write(updated, to: supportDir) }
        return updated
    }

    // MARK: Replacements

    @discardableResult
    func addReplacement(heard: String, replace: String, regex: Bool = false) -> Bool {
        let result = try? mutateReplacements { set in
            if regex {
                set.rules.append(.init(heard: heard.trimmingCharacters(in: .whitespacesAndNewlines), replace: replace, regex: true))
            } else {
                set = set.addingLiteral(heard: heard, replace: replace)
            }
        }
        return result != nil
    }

    @discardableResult
    func mutateReplacements(_ transform: (inout ReplacementsSet) -> Void) throws -> ReplacementsSet {
        var set = try loadReplacementsForMutation()
        transform(&set)
        try commit { try ReplacementsStore.write(set, to: supportDir) }
        return set
    }

    // MARK: Modes

    func writeMode(_ mode: Mode) throws {
        try commit { try ModeStore.write(mode, to: modesDir) }
    }

    func deleteMode(_ mode: Mode) throws {
        try commit {
            try ModeStore.delete(mode, from: modesDir)
            try? FileManager.default.removeItem(
                at: supportDir.appendingPathComponent("lkg/modes", isDirectory: true)
                    .appendingPathComponent("\(mode.id).toml"))
        }
    }

    // Re-slug a mode's file (the id is the filename stem). One operation: write the new file, then delete
    // the old; if the delete fails, roll the new file back so a failed rename can never leave a DUPLICATE
    // mode on disk (it leaves the original untouched and surfaces the error) — and it invalidates once, not
    // twice.
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
        try commit {
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

    // MARK: Connections

    // Read-modify-write from disk (like the dictionary/replacements mutators): insert-or-replace by id, so
    // a connection written by another surface (first-run, a concurrent pane) between this model's snapshot
    // and its save is never clobbered. Returns the fresh set.
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
        try commit { try ConnectionStore.write(set, to: supportDir) }
        return set
    }

    // Write succeeds → invalidate the cache so the next dictation sees it, then notify the host. On a
    // throw nothing is invalidated (the on-disk state is unchanged) and the error propagates.
    private func commit(_ write: () throws -> Void) throws {
        try write()
        config.invalidate()
        onChange?()
    }

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
