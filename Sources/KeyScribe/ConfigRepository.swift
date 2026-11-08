import Foundation
import KeyScribeKit

extension Notification.Name {
    static let replacementUsageDidChange = Notification.Name("KeyScribe.replacementUsageDidChange")
}

// The single owner of on-disk config writes (dictionary, replacements, modes, connections). Every mutation
// is a fresh read-modify-write from disk (so a concurrent write from another surface — the global
// Add-to-Vocabulary hotkey while a Settings pane is open — is never clobbered by stale in-memory state),
// then invalidates the ConfigCache immediately so the next dictation sees the change without waiting on the
// FSEvents watcher. The watcher stays only as a backstop for external edits (an extra invalidate is
// idempotent). `onChange` lets the host refresh dependent UI (menu status).
//
// Mutators THROW so a Settings pane can surface the failure; the `add*` helpers wrap them into a Bool or an
// AddResult for correction-surface callers (menu, History detail, correction panel).
// settings.toml is NOT owned here — it is a whole-object write routed through AppDelegate.applySettings
// (external edits absorbed only via the FSEvents reload path); read-modify-write would buy little there.
@MainActor
final class ConfigRepository {
    let supportDir: URL
    private let config: ConfigCache

    // What the running app is using for a file that failed to load, as the config cache recorded it — nil
    // when the cache has no failure for it (so nothing may be claimed about what still works).
    func runningState(of relativePath: String) -> ConfigFileIssue.Recovery? {
        for issue in config.fileFailures where issue.relativePath == relativePath {
            if case .unreadable(let recovery) = issue.kind { return recovery }
        }
        return nil
    }
    private let selfWriteGate: ConfigSelfWriteGate
    let replacementUsage: ReplacementUsageStore?
    var onChange: (() -> Void)?
    // In-app observers (beyond the host's `onChange`) that re-read from disk when any surface writes config —
    // notably the Settings pane models, whose drafts would otherwise clobber a term the correction panel
    // routed into a mode while the pane was open.
    private var changeObservers: [() -> Void] = []

    init(
        supportDir: URL, config: ConfigCache, selfWriteGate: ConfigSelfWriteGate = ConfigSelfWriteGate(),
        replacementUsage: ReplacementUsageStore? = nil
    ) {
        self.supportDir = supportDir
        self.config = config
        self.selfWriteGate = selfWriteGate
        self.replacementUsage = replacementUsage
    }

    func reconcileReplacementUsage() {
        guard let replacementUsage, config.configFileError == nil else { return }
        replacementUsage.reconcile(
            keys: ReplacementUsage.configuredKeys(
                global: config.replacements, modes: config.storedModes, shared: config.shared))
    }

    func addChangeObserver(_ observer: @escaping () -> Void) {
        changeObservers.append(observer)
    }

    // For the FSEvents external-edit reload path (AppDelegate.reloadConfig), which performs the host's
    // `onChange` effects itself: refresh only the in-app observers so an open Settings pane re-reads a
    // file edited outside the app.
    func notifyExternalChange() {
        reconcileReplacementUsage()
        for observer in changeObservers { observer() }
    }

    private func notifyChange() {
        reconcileReplacementUsage()
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

    var resolved: ResolvedConfig { config.resolved }
    var voiceCommandsEnabled: Bool { config.voiceCommandsEnabled }
    var findsInAppsEnabled: Bool { config.findsInAppsEnabled }
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

    enum AddResult: Equatable {
        case saved
        case refused(String)
        // Saving would leave shared vocabularies disagreeing; the vocabulary named is where to settle it.
        case needsChoice(String, vocabularyId: String)
        case failed
    }

    func addDictionaryWord(_ word: String, to scope: CorrectionDestination.Scope) -> AddResult {
        addResult {
            switch scope {
            case .global: try mutateDictionary { $0.adding(word: word) }
            case .mode(let id):
                try mutateMode(id: id) { mode in
                    mode.dictionary.words = DictionarySet(words: mode.dictionary.words).adding(word: word).words
                }
            case .shared(let id):
                try commitVocabularyChange(
                    shared: (id, { $0.words = DictionarySet(words: $0.words).adding(word: word).words }), modes: [:])
            }
        }
    }

    func addReplacement(
        heard: String, replace: String, regex: Bool = false, wholeDictation: Bool? = nil, to scope: CorrectionDestination.Scope
    ) -> AddResult {
        addResult {
            switch scope {
            case .global:
                try mutateReplacements { $0 = $0.adding(heard: heard, replace: replace, regex: regex, wholeDictation: wholeDictation) }
            case .mode(let id):
                try mutateMode(id: id) { mode in
                    mode.replacements.rules = ReplacementsSet(rules: mode.replacements.rules)
                        .adding(heard: heard, replace: replace, regex: regex, wholeDictation: wholeDictation).rules
                }
            case .shared(let id):
                try commitVocabularyChange(shared: (id, {
                    $0.rules = ReplacementsSet(rules: $0.rules)
                        .adding(heard: heard, replace: replace, regex: regex, wholeDictation: wholeDictation).rules
                }), modes: [:])
            }
        }
    }

    private func addResult(_ save: () throws -> Void) -> AddResult {
        do {
            try save()
            return .saved
        } catch let disagreement as Disagreement {
            guard let id = disagreement.vocabularyId else { return .refused(disagreement.localizedDescription) }
            return .needsChoice(disagreement.localizedDescription, vocabularyId: id)
        } catch {
            let underlying = (error as? VocabularyFileFailure)?.underlying ?? error
            if let refused = underlying as? UnreadKeys { return .refused(refused.localizedDescription) }
            return .failed
        }
    }

    func vocabularyScope(for scope: CorrectionDestination.Scope) -> VocabularyScope {
        let globalWords = dictionaryWords()
        let globalRules = replacementRules()
        switch scope {
        case .global:
            return VocabularyScope(globalWords: globalWords, globalRules: globalRules)
        case .shared(let id):
            guard let vocabulary = resolved.shared.first(where: { $0.id == id }) else { return VocabularyScope() }
            return VocabularyScope(globalWords: vocabulary.words, globalRules: vocabulary.rules)
        case .mode(let id):
            guard let mode = resolved.modes.first(where: { $0.id == id }) else {
                return VocabularyScope(globalWords: globalWords, globalRules: globalRules)
            }
            return VocabularyScope.of(mode, globalWords: globalWords, globalRules: globalRules, shared: resolved.shared)
        }
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

    enum BatchOutcome: Equatable {
        enum StaleReason: Equatable { case rulesChanged, wordRemoved, destinationMissing }
        case saved
        case stale(StaleReason)
        case disagreement(String)
    }

    func saveReplacementBatch(
        to destination: ReplacementPreview.Destination, expected: [ReplacementsSet.Rule],
        proposed: [ReplacementsSet.Rule], requiringWord word: String?
    ) throws -> BatchOutcome {
        func contains(_ words: [String]) -> Bool {
            guard let word else { return true }
            return words.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
        }
        switch destination {
        case .global:
            guard contains(try loadDictionaryForMutation().words) else { return .stale(.wordRemoved) }
            guard try loadReplacementsForMutation().rules == expected else { return .stale(.rulesChanged) }
            try commit(touching: [supportDir.appendingPathComponent(ReplacementsStore.fileName)]) {
                try ReplacementsStore.write(ReplacementsSet(rules: proposed), to: supportDir)
            }
        case .mode(let id):
            guard FileManager.default.fileExists(atPath: modeFileURL(id: id).path) else {
                return .stale(.destinationMissing)
            }
            var mode = try loadModeForMutation(id: id)
            guard mode.hasOwnVocabulary else { return .stale(.destinationMissing) }
            guard contains(mode.dictionary.words) else { return .stale(.wordRemoved) }
            guard mode.replacements.rules == expected else { return .stale(.rulesChanged) }
            mode.replacements.rules = proposed
            try writeMode(mode)
        case .shared(let id):
            let file = SharedVocabularyStore.fileURL(id: id, in: sharedVocabularyDir)
            guard FileManager.default.fileExists(atPath: file.path) else { return .stale(.destinationMissing) }
            let current = try SharedVocabularyStore.decode(from: readForMutation(file), id: id)
            guard contains(current.words) else { return .stale(.wordRemoved) }
            guard current.rules == expected else { return .stale(.rulesChanged) }
            do {
                try commitVocabularyChange(shared: (id, { vocabulary in
                    guard vocabulary.rules == expected else { throw StaleBatch() }
                    vocabulary.rules = proposed
                }), modes: [:])
            } catch is StaleBatch {
                return .stale(.rulesChanged)
            } catch let disagreement as Disagreement {
                return .disagreement(disagreement.localizedDescription)
            }
        }
        return .saved
    }

    // A save re-encodes the whole file from what was decoded, so a key nothing reads would be deleted by it.
    struct UnreadKeys: LocalizedError {
        let relativePath: String
        let keys: [UnknownConfigKey]
        var errorDescription: String? {
            let line = keys.count == 1 ? "that line" : "those lines"
            return "\(relativePath) has \(keys.map(\.description).joined(separator: ", ")), which \(Branding.appName) "
                + "doesn’t read. Saving here would delete \(line), so nothing was saved. Fix or remove \(line) in "
                + "the file, then try again."
        }
    }

    private func refuseUnreadKeys(_ toml: String, in file: URL, _ unknownKeys: (String) -> [UnknownConfigKey]) throws {
        let keys = unknownKeys(toml)
        guard !keys.isEmpty else { return }
        let relativePath = String(file.path.dropFirst(supportDir.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        throw UnreadKeys(relativePath: relativePath, keys: keys)
    }

    struct UnreadableModeFile: LocalizedError {
        let fileName: String
        let error: ConfigError
        var errorDescription: String? {
            "\(fileName) has an error. Fix the file before changing this mode here, or saving would replace your edit."
        }
    }

    func writeMode(_ mode: Mode) throws {
        try requireReadableModeFile(id: mode.id)
        try commit(touching: [modeFileURL(id: mode.id)]) { try ModeStore.write(mode, to: modesDir) }
    }

    private func requireReadableModeFile(id: String) throws {
        let url = modeFileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let toml: String
            do { toml = try String(contentsOf: url, encoding: .utf8) }
            catch { throw ConfigError.unreadableFile(error.localizedDescription) }
            _ = try ModeStore.decode(from: toml, id: id)
            try refuseUnreadKeys(toml, in: url, ModeStore.unknownKeys(in:))
        } catch let refused as UnreadKeys {
            throw refused
        } catch {
            throw UnreadableModeFile(
                fileName: url.lastPathComponent, error: (error as? ConfigError) ?? .invalid("\(error)"))
        }
    }

    struct IncompleteRestore: Error {
        let underlying: Error
        let unrestored: [String]
    }

    func writeModes(
        _ modes: [Mode], restoring originals: [Mode], using write: ((Mode) throws -> Void)? = nil
    ) throws {
        for mode in modes { try requireReadableModeFile(id: mode.id) }
        let write = write ?? { [modesDir] in try ModeStore.write($0, to: modesDir) }
        try commit(touching: modes.map { modeFileURL(id: $0.id) }) {
            var written: Set<String> = []
            do {
                for mode in modes {
                    try write(mode)
                    written.insert(mode.id)
                }
            } catch {
                let unrestored = originals.filter { written.contains($0.id) }.compactMap { original -> String? in
                    (try? write(original)) == nil ? original.name : nil
                }
                guard unrestored.isEmpty else {
                    config.invalidate()
                    notifyChange()
                    throw IncompleteRestore(underlying: error, unrestored: unrestored)
                }
                throw error
            }
        }
    }

    @discardableResult
    func mutateMode(id: String, _ transform: (inout Mode) -> Void) throws -> Mode {
        var mode = try loadModeForMutation(id: id)
        guard mode.hasOwnVocabulary else { throw ConfigError.invalid("Plain Dictation uses only global vocabulary") }
        transform(&mode)
        try writeMode(mode)
        return mode
    }

    // MARK: Shared vocabularies

    var sharedVocabularyDir: URL { SharedVocabularyStore.directory(in: supportDir) }

    func sharedVocabularies() -> [SharedVocabulary] { SharedVocabularyStore.load(in: sharedVocabularyDir).vocabularies }

    struct NameProblem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // A new vocabulary starts empty and used by no mode. Its id never matches one a mode still lists, so a mode
    // that pointed at a deleted vocabulary does not pick up a new one by accident.
    @discardableResult
    func createSharedVocabulary(named name: String) throws -> SharedVocabulary {
        let existing = sharedVocabularies()
        if let problem = SharedVocabularyStore.nameProblem(name, among: existing) { throw NameProblem(message: problem) }
        let referenced = ModeStore.loadAll(in: modesDir).flatMap(\.sharedVocabularies)
        let id = SharedVocabularyStore.newId(for: name, existing: Set(existing.map(\.id) + referenced))
        let vocabulary = SharedVocabulary(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        try commit(touching: [SharedVocabularyStore.fileURL(id: id, in: sharedVocabularyDir)]) {
            try SharedVocabularyStore.write(vocabulary, to: sharedVocabularyDir)
        }
        return vocabulary
    }

    @discardableResult
    func mutateSharedVocabulary(id: String, _ transform: (inout SharedVocabulary) -> Void) throws -> SharedVocabulary {
        let file = SharedVocabularyStore.fileURL(id: id, in: sharedVocabularyDir)
        let toml = try readForMutation(file)
        var vocabulary = try SharedVocabularyStore.decode(from: toml, id: id)
        try refuseUnreadKeys(toml, in: file, SharedVocabularyStore.unknownKeys(in:))
        transform(&vocabulary)
        try commit(touching: [file]) { try SharedVocabularyStore.write(vocabulary, to: sharedVocabularyDir) }
        return vocabulary
    }

    func renameSharedVocabulary(id: String, to name: String) throws {
        if let problem = SharedVocabularyStore.nameProblem(name, among: sharedVocabularies(), renaming: id) {
            throw NameProblem(message: problem)
        }
        try mutateSharedVocabulary(id: id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // Which modes use a vocabulary. Plain Dictation never does.
    func setSharedVocabulary(id: String, usedBy modeIds: Set<String>) throws {
        var changes: [String: (inout Mode) -> Void] = [:]
        for mode in ModeStore.loadAll(in: modesDir) where mode.hasOwnVocabulary {
            guard mode.sharedVocabularies.contains(id) != modeIds.contains(mode.id) else { continue }
            changes[mode.id] = { $0.setUsing(id, modeIds.contains($0.id)) }
        }
        try commitVocabularyChange(modes: changes)
    }

    // A change that would leave shared vocabularies disagreeing in a mode, refused before anything is written.
    struct Disagreement: LocalizedError {
        let vocabularyId: String?
        let vocabularyName: String?
        let items: [SharedVocabularyConflicts.Introduced]

        var errorDescription: String? {
            guard let first = items.first else { return nil }
            var sources: [String] = []
            for source in first.competition.options.flatMap(\.sources) where !sources.contains(source) { sources.append(source) }
            let where_ = vocabularyName.map { "Add it from Settings \u{25B8} Vocabulary \u{25B8} \($0) instead, where you can choose" }
                ?? "Choose in Settings \u{25B8} Vocabulary"
            let more = items.count > 1 ? " It would also leave \(items.count - 1) more to settle." : ""
            return "This would make \(ListFormatter.localizedString(byJoining: sources)) disagree about "
                + "\u{201C}\(first.competition.phrase)\u{201D} in \(first.modeName). \(where_) which one \(first.modeName) uses.\(more)"
        }
    }

    // A file the change needed could not be read, so nothing was written.
    struct VocabularyFileFailure: Error {
        let file: URL
        let relativePath: String
        let underlying: Error
    }

    // One change to a shared vocabulary and the modes it needs, written together: each file is re-read at write
    // time, a change that would leave shared vocabularies disagreeing anywhere is refused, and anything already
    // written is put back if a later write fails. Every save into a shared vocabulary goes through here.
    func commitVocabularyChange(
        shared change: (id: String, transform: (inout SharedVocabulary) throws -> Void)? = nil,
        modes changes: [String: (inout Mode) -> Void]
    ) throws {
        var originals: [Mode] = []
        var updated: [Mode] = []
        for (id, transform) in changes.sorted(by: { $0.key < $1.key }) {
            let original = try readingFile(modeFileURL(id: id), "modes/\(id).toml") { try loadModeForMutation(id: id) }
            guard original.hasOwnVocabulary else { throw ConfigError.invalid("Plain Dictation uses only global vocabulary") }
            var mode = original
            transform(&mode)
            guard mode != original else { continue }
            originals.append(original)
            updated.append(mode)
        }
        var file: URL?
        var before: SharedVocabulary?
        var after: SharedVocabulary?
        if let change {
            let url = SharedVocabularyStore.fileURL(id: change.id, in: sharedVocabularyDir)
            let original = try readingFile(url, "\(SharedVocabularyStore.directoryName)/\(change.id).toml") {
                let toml = try readForMutation(url)
                let vocabulary = try SharedVocabularyStore.decode(from: toml, id: change.id)
                try refuseUnreadKeys(toml, in: url, SharedVocabularyStore.unknownKeys(in:))
                return vocabulary
            }
            var vocabulary = original
            try change.transform(&vocabulary)
            if vocabulary != original { (file, before, after) = (url, original, vocabulary) }
        }
        guard after != nil || !updated.isEmpty else { return }
        let modesBefore = ModeStore.loadAll(in: modesDir)
        let sharedBefore = sharedVocabularies()
        let introduced = SharedVocabularyConflicts.introduced(
            modesBefore: modesBefore, sharedBefore: sharedBefore,
            modesAfter: modesBefore.map { mode in updated.first { $0.id == mode.id } ?? mode },
            sharedAfter: sharedBefore.map { $0.id == after?.id ? after! : $0 })
        if !introduced.isEmpty { throw Disagreement(vocabularyId: after?.id, vocabularyName: after?.name, items: introduced) }
        if let file, let after {
            try commit(touching: [file]) { try SharedVocabularyStore.write(after, to: sharedVocabularyDir) }
        }
        guard !updated.isEmpty else { return }
        do {
            try writeModes(updated, restoring: originals)
        } catch let writeError {
            guard let file, let before else { throw writeError }
            do {
                try commit(touching: [file]) { try SharedVocabularyStore.write(before, to: sharedVocabularyDir) }
            } catch {
                let unrestored = ((writeError as? IncompleteRestore)?.unrestored ?? []) + [before.name]
                throw IncompleteRestore(underlying: writeError, unrestored: unrestored)
            }
            throw writeError
        }
    }

    private func readingFile<T>(_ file: URL, _ relativePath: String, _ read: () throws -> T) throws -> T {
        do { return try read() } catch { throw VocabularyFileFailure(file: file, relativePath: relativePath, underlying: error) }
    }

    private struct StaleBatch: Error {}

    struct MoveConflict: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // The entry joins the vocabulary and leaves the mode, which starts using the vocabulary so it keeps the entry.
    // `settlements` are the entries of each mode's own that settle what the move leaves disagreeing there.
    func moveToSharedVocabulary(
        _ entry: SharedVocabularyMove.Entry, fromMode modeId: String, to vocabularyId: String,
        settlements: [String: PendingAttachment.Settlement]
    ) throws {
        let file = SharedVocabularyStore.fileURL(id: vocabularyId, in: sharedVocabularyDir)
        let destination = try SharedVocabularyStore.decode(from: readForMutation(file), id: vocabularyId)
        let origin = try loadModeForMutation(id: modeId)
        if let conflict = SharedVocabularyMove.plan(entry, from: origin, to: destination, modes: []).conflict {
            throw MoveConflict(message: conflict)
        }
        var changes: [String: (inout Mode) -> Void] = settlements.mapValues { settlement in { $0.settle(settlement) } }
        let settleOrigin = changes[modeId]
        changes[modeId] = { mode in
            var vocabulary = destination
            SharedVocabularyMove.apply(entry, to: &vocabulary, from: &mode)
            settleOrigin?(&mode)
        }
        try commitVocabularyChange(
            shared: (vocabularyId, { vocabulary in
                var scratch = origin
                SharedVocabularyMove.apply(entry, to: &vocabulary, from: &scratch)
            }),
            modes: changes)
    }

    // The modes stop using it first, so a failure never leaves a mode pointing at a vocabulary that is gone.
    func deleteSharedVocabulary(id: String) throws {
        try setSharedVocabulary(id: id, usedBy: [])
        let file = SharedVocabularyStore.fileURL(id: id, in: sharedVocabularyDir)
        try commit(touching: [file]) { try SharedVocabularyStore.delete(id: id, from: sharedVocabularyDir) }
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
        try requireReadableModeFile(id: mode.id)
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
            replacementUsage?.renameMode(mode.id, to: newId)
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

    @discardableResult
    func mutateVoiceCommands(_ transform: (inout VoiceCommandConfig) throws -> Void) throws -> VoiceCommandConfig {
        var config = try loadVoiceCommandsForMutation()
        try transform(&config)
        if let issue = config.issue { throw ConfigError.invalid(issue) }
        try commit(touching: [supportDir.appendingPathComponent(VoiceCommandStore.fileName)]) {
            try VoiceCommandStore.write(config, to: supportDir)
        }
        return config
    }

    private func loadVoiceCommandsForMutation() throws -> VoiceCommandConfig {
        let file = supportDir.appendingPathComponent(VoiceCommandStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return VoiceCommandConfig() }
        let toml = try readForMutation(file)
        let config = try VoiceCommandStore.decode(from: toml)
        try refuseUnreadKeys(toml, in: file, VoiceCommandStore.unknownKeys(in:))
        return config
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

    // Every read-for-edit failure is a ConfigError, so a caller can tell "couldn't read the file" (resolved
    // once it reads again) from a failed write (resolved only by a write that succeeds).
    private func loadDictionaryForMutation() throws -> DictionarySet {
        let file = supportDir.appendingPathComponent(DictionaryStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return DictionarySet() }
        let toml = try readForMutation(file)
        let set = try DictionaryStore.decode(from: toml)
        try refuseUnreadKeys(toml, in: file, DictionaryStore.unknownKeys(in:))
        return set
    }

    private func loadReplacementsForMutation() throws -> ReplacementsSet {
        let file = supportDir.appendingPathComponent(ReplacementsStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return ReplacementsSet() }
        let toml = try readForMutation(file)
        let set = try ReplacementsStore.decode(from: toml)
        try refuseUnreadKeys(toml, in: file, ReplacementsStore.unknownKeys(in:))
        return set
    }

    private func loadModeForMutation(id: String) throws -> Mode {
        let file = modeFileURL(id: id)
        let toml = try readForMutation(file)
        let mode = try ModeStore.decode(from: toml, id: id)
        try refuseUnreadKeys(toml, in: file, ModeStore.unknownKeys(in:))
        return mode
    }

    private func loadConnectionsForMutation() throws -> ConnectionSet {
        let file = supportDir.appendingPathComponent(ConnectionStore.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return ConnectionSet() }
        let toml = try readForMutation(file)
        let set = try ConnectionStore.decode(from: toml)
        try refuseUnreadKeys(toml, in: file, ConnectionStore.unknownKeys(in:))
        return set
    }

    private func readForMutation(_ file: URL) throws -> String {
        do { return try String(contentsOf: file, encoding: .utf8) }
        catch { throw ConfigError.unreadableFile(error.localizedDescription) }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError
    }
}
