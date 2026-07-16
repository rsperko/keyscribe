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

    private let repository: ConfigRepository
    private var modesDir: URL { repository.modesDir }
    private var supportDir: URL { repository.supportDir }
    private var ledgerDir: URL { supportDir.appendingPathComponent("lkg", isDirectory: true) }
    private var loadedSignature: String?

    // True while this model is writing, so the change observer skips the reentrant reload the write's own
    // `onChange` fires — that reload would land mid-mutation and corrupt the create/rename selection state.
    // External writes run with this false and do reload.
    private var isApplyingLocalMutation = false

    init(repository: ConfigRepository) {
        self.repository = repository
        reload()
        // Refresh from disk on any external config write (e.g. a mode-scoped term from the correction
        // panel) so it survives the pane's next full-file save. `reload` is signature-guarded.
        repository.addChangeObserver { [weak self] in
            guard let self, !self.isApplyingLocalMutation else { return }
            self.reload()
        }
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
        ModeStore.ensureSystemModes(in: modesDir, lkgDir: lkgModesDir)
        let result = ModeStore.load(in: modesDir, previous: modes, lkgDir: lkgModesDir)
        modes = result.modes
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
        let mode = mode.isSystem ? mode.systemNormalized() : mode
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
