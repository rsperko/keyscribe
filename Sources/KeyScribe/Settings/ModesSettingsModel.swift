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
    private var loadedSignature: String?

    init(repository: ConfigRepository) {
        self.repository = repository
        reload()
    }

    // Re-read modes, connections, and fragments from disk. `.onAppear` calls this on every visit to the
    // pane, but the model's own mutators keep memory in sync with disk — so when nothing on disk has
    // changed since the last load (the common navigate-away-and-back case) the decode is skipped. The
    // signature covers everything reload reads; a mutator's own write changes it, costing at most one
    // redundant reload on the next visit.
    func reload(force: Bool = false) {
        guard force || configSignature() != loadedSignature else { return }
        let lkgModesDir = supportDir.appendingPathComponent("lkg", isDirectory: true).appendingPathComponent("modes", isDirectory: true)
        ModeStore.ensureSystemModes(in: modesDir, lkgDir: lkgModesDir)
        let result = ModeStore.load(in: modesDir, previous: modes, lkgDir: lkgModesDir)
        modes = result.modes
        loadFailures = result.failures
        connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        fragmentIds = loadFragmentIds()
        if selectedID == nil || !modes.contains(where: { $0.id == selectedID }) {
            selectedID = modes.first?.id
        }
        loadedSignature = configSignature()
        error = nil
    }

    private func configSignature() -> String {
        let connections = FileFingerprint.file(supportDir.appendingPathComponent(ConnectionStore.fileName))
        return "m:\(FileFingerprint.dir(modesDir))|c:\(connections)|f:\(FileFingerprint.dir(fragmentsDir))"
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

    // Duplicate an existing mode into a new user-created mode. The system Direct floor is not
    // duplicable. The copy drops the seed identity (it is now user-created) and its trigger keys, so it
    // never silently clashes with the original's shortcut — the user assigns a new one.
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

    // A freshly created mode's id is the slug of the placeholder "New Mode". The first time the user
    // gives it a real name, re-slug the id so the TOML filename matches the name instead of staying
    // "new-mode" (the id is the filename stem). Only the initial naming re-slugs; later renames keep
    // the file so external references stay stable.
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
            try repository.renameMode(mode, to: newId)
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
            try repository.deleteMode(mode)
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

    // Create (or resolve) a fragment file by name and refresh the list. Returns the fragment id to
    // add to the mode; the caller opens it in the in-app editor to fill in the instruction text.
    func addFragmentFile(named name: String) -> String? {
        do {
            let (id, created) = try FragmentStore.createIfNeeded(name: name, in: fragmentsDir)
            if created { repository.recordSelfWrite(at: fragmentsDir.appendingPathComponent("\(id).md")) }
            fragmentIds = loadFragmentIds()
            error = nil
            return id
        } catch {
            self.error = "Could not create the instruction file: \(error.localizedDescription)"
            return nil
        }
    }

    func fragmentBody(_ id: String) -> String {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return FragmentStore.body(ofFile: content)
    }

    func saveFragmentBody(_ id: String, _ body: String) {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        do {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try FragmentStore.replacingBody(inFile: content, with: body)
                .write(to: url, atomically: true, encoding: .utf8)
            repository.recordSelfWrite(at: url)
            error = nil
        } catch {
            self.error = "Could not save the instruction: \(error.localizedDescription)"
        }
    }

    func revealFragment(_ id: String) {
        let url = fragmentsDir.appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Closing the editor on an empty instruction discards it: detach from the editing mode and, when
    // no other mode still references it, delete the file. So an instruction created but never written
    // never persists — an empty one is not a saveable instruction.
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
            let url = fragmentsDir.appendingPathComponent("\(id).md")
            try? FileManager.default.removeItem(at: url)
            repository.recordSelfWrite(at: url)
            fragmentIds = loadFragmentIds()
        }
    }

    private func save(_ mode: Mode) {
        let mode = mode.isSystem ? mode.systemNormalized() : mode
        do {
            try repository.writeMode(mode)
            if let index = modes.firstIndex(where: { $0.id == mode.id }) {
                modes[index] = mode
            } else {
                modes.append(mode)
            }
            error = nil
        } catch {
            self.error = "Could not save \(mode.name): \(error.localizedDescription)"
        }
    }
}
