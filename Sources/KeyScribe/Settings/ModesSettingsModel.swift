import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class ModesSettingsModel: ObservableObject {
    @Published private(set) var modes: [Mode] = []
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var fragmentIds: [String] = []
    @Published private(set) var fragmentNames: [String: String] = [:]
    @Published var selectedID: String?
    @Published var lastCreatedId: String?
    private var awaitingInitialName: String?
    @Published private(set) var error: String?
    @Published private(set) var loadFailures: [ModeStore.LoadFailure] = []
    @Published private(set) var pendingMove: ShortcutMove?
    @Published private var appliedMove: AppliedShortcutMove?
    private var pendingMoveBase: Mode?
    private var pendingClaim: [Mode.TriggerKey] = []

    struct AppliedShortcutMove: Equatable {
        let move: ShortcutMove
        let destinationBefore: Mode
        let modesBefore: [Mode]
    }

    private let repository: ConfigRepository
    private var modesDir: URL { repository.modesDir }
    private var supportDir: URL { repository.supportDir }
    private var ledgerDir: URL { supportDir.appendingPathComponent("lkg", isDirectory: true) }
    private var loadedSignature: String?

    // True while this model is writing, so the change observer skips the reentrant reload the write's own
    // `onChange` fires — that reload would land mid-mutation and corrupt the create/rename selection state.
    // External writes run with this false and do reload.
    private var isApplyingLocalMutation = false

    private(set) var voiceCommandsEnabled: Bool
    let voiceCommands: VoiceCommandsSettingsModel

    init(repository: ConfigRepository, voiceCommandsEnabled: Bool = false) {
        self.repository = repository
        self.voiceCommandsEnabled = voiceCommandsEnabled
        voiceCommands = VoiceCommandsSettingsModel(repository: repository)
        reload()
        // Refresh from disk on any external config write (e.g. a mode-scoped term from the correction
        // panel) so it survives the pane's next full-file save. `reload` is signature-guarded.
        repository.addChangeObserver { [weak self] in
            guard let self, !self.isApplyingLocalMutation else { return }
            self.reload()
        }
    }

    func setVoiceCommandsEnabled(_ enabled: Bool) {
        guard enabled != voiceCommandsEnabled else { return }
        voiceCommandsEnabled = enabled
        reload(force: true)
    }

    private func applyingLocalMutation<T>(_ body: () throws -> T) rethrows -> T {
        let previous = isApplyingLocalMutation
        isApplyingLocalMutation = true
        defer { isApplyingLocalMutation = previous }
        return try body()
    }

    // `.onAppear` calls this on every pane visit, but the decode is skipped when the signature is unchanged
    // — mutators keep memory in sync, so navigate-away-and-back costs nothing.
    func reload(force: Bool = false) {
        guard force || configSignature() != loadedSignature else { return }
        let lkgModesDir = supportDir.appendingPathComponent("lkg", isDirectory: true).appendingPathComponent("modes", isDirectory: true)
        ModeStore.ensureSystemModes(in: modesDir, lkgDir: lkgModesDir, voiceCommands: voiceCommandsEnabled)
        let result = ModeStore.load(in: modesDir, previous: modes, lkgDir: lkgModesDir)
        modes = Mode.visible(result.modes, voiceCommands: voiceCommandsEnabled)
        loadFailures = result.failures
        connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        fragmentIds = loadFragmentIds()
        let selectionStillValid = selectedID != nil
            && (modes.contains { $0.id == selectedID } || ModeStore.templates().contains { $0.id == selectedID })
        if !selectionStillValid {
            // A fresh, templates-only install lands on the first user mode if one exists; otherwise leave the
            // detail empty (the Start-from-a-Template section is visible in the list either way).
            selectedID = modes.contains { !$0.isSystem } ? modes.first?.id : nil
        }
        loadedSignature = configSignature()
        error = nil
        appliedMove = nil
    }

    private func configSignature() -> String {
        let connections = FileFingerprint.file(supportDir.appendingPathComponent(ConnectionStore.fileName))
        let dictionary = FileFingerprint.file(supportDir.appendingPathComponent(DictionaryStore.fileName))
        let replacements = FileFingerprint.file(supportDir.appendingPathComponent(ReplacementsStore.fileName))
        return "m:\(FileFingerprint.dir(modesDir))|c:\(connections)|f:\(FileFingerprint.dir(fragmentsDir))|d:\(dictionary)|r:\(replacements)"
    }

    func create() {
        let name = "New Mode"
        var mode = Mode(id: ModeStore.newID(for: name, existing: modes.map(\.id)), name: name)
        mode.trailing = .space
        mode.commands.liveEdits = true
        save(mode)
        selectedID = mode.id
        lastCreatedId = mode.id
        awaitingInitialName = mode.id
    }

    func consumeCreated() { lastCreatedId = nil }

    // Like create() it autofocuses the name; it does NOT enable the mode — it stays disabled until the user
    // configures it in the editor, consistent with the pendingConnectOffer consent pattern.
    func createWithConnection(connectionId: String) {
        let name = "New Mode"
        var mode = Mode(id: ModeStore.newID(for: name, existing: modes.map(\.id)), name: name)
        mode.trailing = .space
        mode.commands.liveEdits = true
        mode.enabled = false
        mode.aiRewrite = Mode.AIRewrite(connection: connectionId, prompt: "")
        save(mode)
        selectedID = mode.id
        lastCreatedId = mode.id
        awaitingInitialName = mode.id
    }

    // At its free catalog id this is a `.seed`, kept migratable via the ledger; if the id is taken it's a
    // `.copy` (plain user mode). No name autofocus — a template name is already meaningful.
    func materializeTemplate(_ seedId: String) {
        guard let template = ModeStore.templates().first(where: { $0.id == seedId }) else { return }
        let materialization = ModeTemplateInstantiation.materialize(
            template: template, existing: modes, connections: connections)
        guard save(materialization.mode) else { return }
        if case .seed(let mode) = materialization {
            applyingLocalMutation { ModeStore.recordMaterializedSeed(mode, ledgerDir: ledgerDir) }
        }
        selectedID = materialization.mode.id
    }

    // Always the full catalog — the first instance materialized at a free catalog id is the migratable seed;
    // adding it again yields a plain suffixed copy, so a template never drops out of the chooser.
    var allTemplates: [Mode] {
        ModeStore.templates()
    }

    // The copy drops the seed identity and trigger keys, so it never clashes with the original's shortcut.
    func duplicate(_ mode: Mode) {
        guard !mode.isSystem else { return }
        let name = "\(mode.name) copy"
        var copy = mode
        copy.id = ModeStore.newID(for: name, existing: modes.map(\.id))
        copy.name = name
        copy.seedId = nil
        copy.seedVersion = nil
        copy.triggerKeys = []
        save(copy)
        selectedID = copy.id
    }

    // The first real name re-slugs the id so the TOML filename matches (the id is the filename stem);
    // later renames keep the file so external references stay stable.
    func update(_ mode: Mode) {
        let previous = modes.first { $0.id == mode.id }
        if let other = VoiceCommandTriggers.clash(for: mode, in: modes) {
            if let previous {
                let added = mode.triggerKeys.filter { key in !previous.triggerKeys.contains { $0.key == key.key } }
                if let move = VoiceCommandTriggers.move(normalized(mode), claiming: added, in: modes) {
                    propose(move, base: previous, claiming: added)
                    return
                }
            }
            if let previous, VoiceCommandTriggers.clash(for: previous, in: modes) != nil {
                save(mode)
                return
            }
            error = mode.runsVoiceCommands
                ? "\(other.name) already uses that shortcut. \(mode.name) needs one no other mode uses."
                : "\(other.name) already uses that shortcut, and it cannot share one with another mode."
            return
        }
        if mode.id == awaitingInitialName {
            let newId = ModeStore.newID(for: mode.name, existing: modes.filter { $0.id != mode.id }.map(\.id))
            if newId != mode.id {
                awaitingInitialName = nil
                rename(mode, to: newId)
                return
            }
        }
        save(mode)
    }

    func proposeMove(to mode: Mode) {
        guard let move = VoiceCommandTriggers.move(normalized(mode), in: modes) else { return }
        propose(move, base: mode, claiming: mode.triggerKeys)
    }

    private func propose(_ move: ShortcutMove, base: Mode, claiming keys: [Mode.TriggerKey]) {
        pendingMove = move
        pendingMoveBase = base
        pendingClaim = keys
        error = nil
    }

    func cancelMove() {
        pendingMove = nil
        pendingMoveBase = nil
        pendingClaim = []
    }

    func confirmMove() {
        guard let pending = pendingMove, let base = pendingMoveBase else { return }
        let claim = pendingClaim
        cancelMove()
        reload()
        guard modes.first(where: { $0.id == base.id }) == base,
              let move = VoiceCommandTriggers.move(pending.destination, claiming: claim, in: modes), move == pending else {
            error = "The modes using that shortcut changed, so nothing was moved. Try again."
            return
        }
        let modesBefore = modes
        guard apply(move.writes, restoring: [base] + move.losses.map(\.before)) else { return }
        appliedMove = AppliedShortcutMove(move: move, destinationBefore: base, modesBefore: modesBefore)
    }

    var undoableMove: AppliedShortcutMove? {
        guard let appliedMove, appliedMove.move.writes.allSatisfy(modes.contains) else { return nil }
        return appliedMove
    }

    func undoMove() {
        guard let applied = undoableMove else { return }
        appliedMove = nil
        reload()
        let restores = applied.move.losses.map(\.before) + [applied.destinationBefore]
        let restored = modes.map { mode in restores.first { $0.id == mode.id } ?? mode }
        guard applied.move.writes.allSatisfy(modes.contains),
              restores.allSatisfy({ Self.clashers($0, in: restored).isSubset(of: Self.clashers($0, in: applied.modesBefore)) }) else {
            error = "Those shortcuts changed since the move, so Undo changed nothing."
            return
        }
        _ = apply(restores, restoring: applied.move.writes)
    }

    private static func clashers(_ mode: Mode, in modes: [Mode]) -> Set<String> {
        Set(VoiceCommandTriggers.move(mode, in: modes)?.losses.map(\.before.id) ?? [])
    }

    private func apply(_ writes: [Mode], restoring originals: [Mode]) -> Bool {
        do {
            try applyingLocalMutation { try repository.writeModes(writes, restoring: originals) }
        } catch let incomplete as ConfigRepository.IncompleteRestore {
            reload(force: true)
            self.error = "Could not move the shortcut, and \(incomplete.unrestored.joined(separator: ", ")) could not be put back: \(incomplete.underlying.localizedDescription). Check their shortcuts."
            return false
        } catch {
            self.error = "Could not move the shortcut, so nothing was changed: \(error.localizedDescription)"
            return false
        }
        for mode in writes {
            if let index = modes.firstIndex(where: { $0.id == mode.id }) { modes[index] = mode }
        }
        error = nil
        return true
    }

    private func normalized(_ mode: Mode) -> Mode {
        mode.isSystem ? mode.systemNormalized() : mode
    }

    private func rename(_ mode: Mode, to newId: String) {
        let oldId = mode.id
        var renamed = mode
        renamed.id = newId
        do {
            try applyingLocalMutation { try repository.renameMode(mode, to: newId) }
            if let index = modes.firstIndex(where: { $0.id == oldId }) {
                modes[index] = renamed
            } else {
                modes.append(renamed)
            }
            if selectedID == oldId { selectedID = newId }
            if lastCreatedId == oldId { lastCreatedId = newId }
            error = nil
        } catch {
            self.error = "Could not save \(mode.name): \(error.localizedDescription)"
        }
    }

    func delete(_ mode: Mode) {
        guard !mode.isSystem else { return }
        do {
            try applyingLocalMutation { try repository.deleteMode(mode) }
            if awaitingInitialName == mode.id { awaitingInitialName = nil }
            modes.removeAll { $0.id == mode.id }
            selectedID = modes.first?.id
            error = nil
        } catch {
            self.error = "Could not delete \(mode.name): \(error.localizedDescription)"
        }
    }

    var selected: Mode? {
        modes.first { $0.id == selectedID }
    }

    private var fragmentsDir: URL { supportDir.appendingPathComponent("fragments", isDirectory: true) }

    private func loadFragmentIds() -> [String] {
        let ids = FragmentStore.ids(in: fragmentsDir)
        fragmentNames = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, FragmentStore.name(id: $0, in: fragmentsDir) ?? $0)
        })
        return ids
    }

    // Caller opens the returned id in the in-app editor to fill in the instruction text.
    func addFragmentFile(named name: String) -> String? {
        do {
            let (id, created) = try FragmentStore.createIfNeeded(name: name, in: fragmentsDir)
            if created { applyingLocalMutation { repository.recordSelfWrite(at: fragmentsDir.appendingPathComponent("\(id).md")) } }
            fragmentIds = loadFragmentIds()
            error = nil
            return id
        } catch {
            self.error = "Could not create the instruction file: \(error.localizedDescription)"
            return nil
        }
    }

    func fragmentBody(_ id: String) -> String {
        guard let url = FragmentStore.url(forID: id, in: fragmentsDir),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return FragmentStore.body(ofFile: content)
    }

    func saveFragmentBody(_ id: String, _ body: String) {
        guard let url = FragmentStore.url(forID: id, in: fragmentsDir) else {
            error = "Could not save the instruction: '\(id)' is not a valid instruction name."
            return
        }
        do {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try FragmentStore.replacingBody(inFile: content, with: body)
                .write(to: url, atomically: true, encoding: .utf8)
            applyingLocalMutation { repository.recordSelfWrite(at: url) }
            error = nil
        } catch {
            self.error = "Could not save the instruction: \(error.localizedDescription)"
        }
    }

    func revealFragment(_ id: String) {
        guard let url = FragmentStore.url(forID: id, in: fragmentsDir),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Closing the editor on an empty instruction discards it: detach from the mode and, if unused elsewhere,
    // delete the file — an instruction created but never written never persists.
    func closeFragment(_ id: String, fromMode modeId: String) {
        guard fragmentBody(id).isEmpty else { return }
        if var mode = modes.first(where: { $0.id == modeId }),
           var rewrite = mode.aiRewrite, rewrite.fragments.contains(id) {
            rewrite.fragments.removeAll { $0 == id }
            mode.aiRewrite = rewrite
            save(mode)
        }
        let stillUsed = modes.contains { $0.aiRewrite?.fragments.contains(id) == true }
        if !stillUsed {
            guard let url = FragmentStore.url(forID: id, in: fragmentsDir) else { return }
            try? FileManager.default.removeItem(at: url)
            applyingLocalMutation { repository.recordSelfWrite(at: url) }
            fragmentIds = loadFragmentIds()
        }
    }

    @discardableResult
    private func save(_ mode: Mode) -> Bool {
        let mode = normalized(mode)
        do {
            try applyingLocalMutation { try repository.writeMode(mode) }
            if let index = modes.firstIndex(where: { $0.id == mode.id }) {
                modes[index] = mode
            } else {
                modes.append(mode)
            }
            error = nil
            return true
        } catch {
            self.error = "Could not save \(mode.name): \(error.localizedDescription)"
            return false
        }
    }
}
