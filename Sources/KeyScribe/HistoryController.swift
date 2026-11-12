import AppKit
import KeyScribeKit
import SwiftUI
import UniformTypeIdentifiers

// The user-language "how this mode was chosen" line for History detail.
// Pure function of the reason (+ the matched phrase / trigger key) so it is directly unit-testable.
enum ModeChoiceLine {
    static func text(reason: ModeChoiceReason?, routedPhrase: String?, triggerDisplay: String?) -> String? {
        switch reason {
        case .oneShot:
            return "Chosen from the menu for this dictation"
        case .triggerKey:
            if let key = triggerDisplay { return "Started by its shortcut (\(key))" }
            return "Started by its shortcut"
        case .contextRule:
            return "Chosen for the app you were in"
        case .spokenPhrase:
            if let phrase = routedPhrase { return "Routed by the spoken phrase \u{201C}\(phrase)\u{201D}" }
            return "Routed by a spoken phrase"
        case .fallback:
            return "Plain Dictation — nothing else matched"
        case nil:
            return nil
        }
    }
}

struct HistoryRow: Identifiable, Sendable {
    let id: String
    let entry: HistoryEntry
    let day: String

    init(entry: HistoryEntry, day: String) {
        self.entry = entry
        self.day = day
        id = Self.identity(entry)
    }

    private static func identity(_ entry: HistoryEntry) -> String {
        if let id = entry.id { return "id|\(id)" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        let outcome = entry.outcome.isCommand ? HistoryEntry.Outcome.command.rawValue : entry.outcome.rawValue
        for byte in "\(entry.modeName)\u{1F}\(entry.heard)\u{1F}\(entry.result)\u{1F}\(outcome)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(entry.timestamp.timeIntervalSince1970)|\(hash)"
    }
}

@MainActor
final class HistoryPaneModel: ObservableObject {
    @Published var query = "" { didSet { scheduleRecompute() } }
    @Published var selection: HistoryRow.ID? {
        didSet {
            guard selection != oldValue else { return }
            refreshHints()
            if speaking != nil { stopSpeaking() }
        }
    }
    private var wantedSelection: HistoryRow.ID?
    @Published private(set) var groups: [(day: String, rows: [HistoryRow])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statsLine: String?
    @Published private(set) var hasStoredHistory = false

    private static let loadLimit = 1000
    private var rows: [HistoryRow] = []
    private var entryIndex: [HistoryRow.ID: HistoryEntry] = [:]
    // The full store read that search filters over, cached for the window's lifetime and keyed on the
    // store signature: re-parsing every day file on each debounced keystroke was the cost this removes.
    // Dropped by `reload()` so any in-app mutation (delete) re-reads rather than serving a stale row.
    private var searchCache: (signature: String, entries: [HistoryEntry])?
    private var recomputeTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    // Bumped by every reload() and by releaseForClose(); a detached load/search task captures it at
    // spawn and its main-actor continuation is dropped if it no longer matches, so a task that already
    // passed its cancellation check cannot repopulate the caches after close (or after a newer reload).
    private var loadGeneration = 0

    private let store: HistoryStore
    private let saveWord: (String, CorrectionDestination.Scope) -> ConfigRepository.AddResult
    private let analyzeWord: (String, CorrectionDestination.Scope) -> VocabularyAnalysis
    private let saveReplacement: (String, String, CorrectionDestination.Scope) -> ConfigRepository.AddResult
    var openSettings: (SettingsDestination) -> Void
    var copyText: ((String) -> Void)?
    var pasteText: ((String) -> Void)?
    enum Speaking: Equatable { case audio, macOSVoice }
    var readWithMacOSVoice: ((String, @escaping () -> Void) -> HistorySpeech.Start)?
    var spokenAudio: ((String) -> SpokenAttempt?)?
    var forgetSpokenAudio: (([String]) -> Void)?
    var chooseSpokenAudioFolder: @MainActor () -> URL? = HistoryPaneModel.askForSpokenAudioFolder
    var revealInFinder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .withoutOverwriting) }
    var playHeldAudio: ((Data, @escaping () -> Void) -> HistorySpeech.Start)?
    var stopHistorySpeech: (() -> Void)?
    @Published private(set) var speaking: Speaking?
    @Published private(set) var spokenAudioChanges = 0
    var rewriteAgain: ((HistoryEntry) async -> DictationController.RewriteAgain)?
    var mishearingHints: ((HistoryEntry) async -> [MishearingHint.Suggestion])?
    @Published private(set) var hints: [MishearingHint.Suggestion] = []
    private(set) var hintsTask: Task<Void, Never>?
    @Published private(set) var rewritingAgain = false
    @Published private(set) var unsavedRewrite: (id: String, text: String)?
    private(set) var rewriteAgainTask: Task<Void, Never>?
    var supportSetup: () -> String = { DiagnosticsCollector.collect().render(includingPrivacyNote: false) }

    // Shared across the main-actor load path and the detached search task; `nonisolated` opts out of the
    // enclosing @MainActor isolation the detached task cannot satisfy (DateFormatter is Sendable and
    // thread-safe for formatting once configured).
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    // Set by Settings: builds the History finder for a word just added, in the scope it was added to.
    var mishearingsFinder: ((String, CorrectionDestination.Scope, @escaping (Int) -> Void) -> HistoryReplacementsModel?)?
    @Published private(set) var mishearings: HistoryReplacementsModel?
    private var foundMishearings: HistoryReplacementsModel?
    private var dictionarySheetClosed = true

    init(
        store: HistoryStore,
        addDictionaryWord: @escaping (String, CorrectionDestination.Scope) -> ConfigRepository.AddResult,
        analyzeDictionaryWord: @escaping (String, CorrectionDestination.Scope) -> VocabularyAnalysis,
        addReplacement: @escaping (String, String, CorrectionDestination.Scope) -> ConfigRepository.AddResult,
        openSettings: @escaping (SettingsDestination) -> Void
    ) {
        self.store = store
        self.saveWord = addDictionaryWord
        self.analyzeWord = analyzeDictionaryWord
        self.saveReplacement = addReplacement
        self.openSettings = openSettings
    }

    func storeSignature() -> String { store.signature() }

    func refreshHistoryAvailability() async {
        let generation = loadGeneration
        let store = store
        let available = await Task.detached(priority: .utility) {
            !store.entries(limit: 1, where: { !$0.isSpokenReplyOnly }).isEmpty
        }.value
        guard generation == loadGeneration, !Task.isCancelled else { return }
        hasStoredHistory = available
    }

    // Drop everything held for the visible window so a closed History window retains no parsed
    // transcripts or the full-store search cache; the next open re-reads from disk.
    func releaseForClose() {
        stopSpeaking()
        wantedSelection = nil
        loadGeneration &+= 1
        recomputeTask?.cancel(); searchTask?.cancel(); statusTask?.cancel()
        selectionTask?.cancel(); reloadTask?.cancel()
        rows = []
        entryIndex = [:]
        searchCache = nil
        groups = []
        selection = nil
        rewriteAgainTask?.cancel()
        rewriteAgainTask = nil
        rewritingAgain = false
        unsavedRewrite = nil
        statsLine = nil
        statusMessage = nil
        isLoading = false
    }

    func reload() {
        isLoading = true
        searchCache = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        let store = self.store
        let limit = Self.loadLimit
        reloadTask?.cancel()
        reloadTask = Task.detached { [weak self] in
            let loaded = store.entries(limit: limit)
            if Task.isCancelled { return }
            await self?.applyLoaded(loaded, generation: generation)
        }
    }

    private func applyLoaded(_ loaded: [HistoryEntry], generation: Int) {
        guard generation == loadGeneration else { return }
        rows = loaded.map { HistoryRow(entry: $0, day: Self.dayFormatter.string(from: $0.timestamp)) }
        hasStoredHistory = loaded.contains { !$0.isSpokenReplyOnly }
        entryIndex = Dictionary(rows.map { ($0.id, $0.entry) }, uniquingKeysWith: { first, _ in first })
        statsLine = Self.statsSummary(HistoryStats.compute(from: loaded))
        recomputeGroups()
        isLoading = false
    }

    private static func statsSummary(_ s: HistoryStats) -> String? {
        guard s.total > 0 else { return nil }
        var parts = [
            "\(s.total) dictation\(s.total == 1 ? "" : "s")",
            "\(s.wordsDictated) word\(s.wordsDictated == 1 ? "" : "s")",
        ]
        if s.cloudCount > 0 { parts.append("\(Int((Double(s.cloudCount) / Double(s.total) * 100).rounded()))% cloud") }
        if s.redactionCount > 0 { parts.append("\(Int((s.redactionRate * 100).rounded()))% redacted") }
        return parts.joined(separator: " · ")
    }

    // Export the CURRENT search/filter selection, reading the FULL store (not the capped in-memory
    // rows) off-main, then a save panel on main — the panel is the consent. Writes only where the user
    // points it; never includes audio (KeyScribe never stores audio) or anything not already on disk.
    func export(format: HistoryExport.Format) {
        let store = self.store
        let query = self.query
        Task { @MainActor [weak self] in
            guard let self else { return }
            let payload = await Task.detached { () -> String in
                let all = store.entries(limit: nil)
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let filtered = trimmed.isEmpty ? all : all.filter { HistorySearch.matches($0, query: trimmed) }
                let dayF = DateFormatter(); dayF.dateStyle = .full; dayF.timeStyle = .none
                let timeF = DateFormatter(); timeF.dateStyle = .none; timeF.timeStyle = .short
                let formatting = HistoryExport.Formatting(
                    day: { dayF.string(from: $0) }, time: { timeF.string(from: $0) })
                return HistoryExport.export(filtered, format: format, formatting: formatting, appName: Branding.appName)
            }.value
            self.presentSavePanel(payload: payload, format: format)
        }
    }

    private func presentSavePanel(payload: String, format: HistoryExport.Format) {
        guard !payload.isEmpty else { flash("Nothing to export."); return }
        let panel = NSSavePanel()
        let slug = Branding.appName.lowercased().replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "\(slug)-history.\(format.fileExtension)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try payload.write(to: url, atomically: true, encoding: .utf8)
            flash("Exported \u{201C}\(url.lastPathComponent)\u{201D}.")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    // Debounce search keystrokes: re-filtering and re-grouping up to loadLimit rows on every character
    // is wasted work while the user is still typing.
    private func scheduleRecompute() {
        recomputeTask?.cancel()
        searchTask?.cancel()
        recomputeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.recomputeGroups()
        }
    }

    private func recomputeGroups() {
        searchTask?.cancel()
        let generation = loadGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            applyFilteredRows(rows, generation: generation)
            return
        }
        let store = self.store
        let signature = store.signature()
        let cachedEntries = searchCache?.signature == signature ? searchCache?.entries : nil
        searchTask = Task.detached { [weak self] in
            let all: [HistoryEntry]
            if let cachedEntries {
                all = cachedEntries
            } else {
                all = store.entries(limit: nil)
                await self?.cacheFullEntries(all, signature: signature, generation: generation)
            }
            let filtered = all
                .filter { HistorySearch.matches($0, query: trimmed) }
                .map { HistoryRow(entry: $0, day: Self.dayFormatter.string(from: $0.timestamp)) }
            if Task.isCancelled { return }
            await self?.applyFilteredRows(filtered, generation: generation)
        }
    }

    private func cacheFullEntries(_ entries: [HistoryEntry], signature: String, generation: Int) {
        guard generation == loadGeneration else { return }
        searchCache = (signature, entries)
    }

    private func applyFilteredRows(_ filtered: [HistoryRow], generation: Int) {
        guard generation == loadGeneration else { return }
        entryIndex = Dictionary(filtered.map { ($0.id, $0.entry) }, uniquingKeysWith: { first, _ in first })
        groups = Dictionary(grouping: filtered, by: \.day)
            .map { (day: $0.key, rows: $0.value) }
            .sorted { ($0.rows.first?.entry.timestamp ?? .distantPast) > ($1.rows.first?.entry.timestamp ?? .distantPast) }
        resolveSelection()
    }

    // Keep a still-present selection so a background reload/search does not yank the user off what they
    // were reading; otherwise fall to the newest visible row. The auto-pick is deferred a tick: a List
    // resets a selection assigned before its rows are in the view tree, so we wait for the rows to commit.
    private func resolveSelection() {
        let visible = Set(groups.flatMap { $0.rows.map(\.id) })
        if let wanted = wantedSelection, !visible.contains(wanted) {
            wantedSelection = nil
            flash("That reply is no longer in History.")
        } else if let wanted = wantedSelection {
            wantedSelection = nil
            selectionTask?.cancel()
            selectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.selection = wanted
            }
            return
        }
        if let selection, visible.contains(selection) { return }
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            let stillVisible = Set(self.groups.flatMap { $0.rows.map(\.id) })
            if let current = self.selection, stillVisible.contains(current) { return }
            self.selection = self.groups.first?.rows.first?.id
        }
    }

    var selected: HistoryEntry? { selection.flatMap { entryIndex[$0] } }
    var hasEntries: Bool { !rows.isEmpty }

    func wouldRemoveHistory(retainingDays: Int) -> Bool {
        !HistoryRetention.expired(
            dayFiles: store.dayFiles(), today: HistoryStore.todayString(), retentionDays: retainingDays
        ).isEmpty
    }

    // Prune the store to the new retention now and re-read, so a lowered retention drops expired rows
    // from the visible list immediately instead of leaving them until the next pane switch. Idempotent
    // with the AppDelegate's settings-driven prune (deletes already-gone files → no-op).
    func applyRetention(days: Int) {
        _ = store.applyRetention(retentionDays: days)
        reload()
    }

    func copyResult() { if let r = selected?.result, !r.isEmpty { copyText?(r) } }
    func copyHeard() { if let h = selected?.heard, !h.isEmpty { copyText?(h) } }
    func copyReply() { if let r = selected?.spokenReply?.text, !r.isEmpty { copyText?(r) } }

    func readReplyWithMacOSVoice() {
        guard let reply = selected?.spokenReply?.text, !reply.isEmpty, let readWithMacOSVoice else { return }
        begin(.macOSVoice) { readWithMacOSVoice(reply, $0) }
    }

    func playSpokenAudio() {
        guard let audio = selectedSpokenAudio?.audio, let playHeldAudio else { return }
        begin(.audio) { playHeldAudio(audio, $0) }
    }

    var canPlaySpokenAudio: Bool { selectedSpokenAudio.map { $0.playback != .playing } ?? false }

    func stopSpeaking() {
        stopHistorySpeech?()
        speaking = nil
    }

    private func begin(_ kind: Speaking, _ start: (@escaping () -> Void) -> HistorySpeech.Start) {
        speaking = kind
        switch start({ [weak self] in if self?.speaking == kind { self?.speaking = nil } }) {
        case .started: break
        case .dictating:
            speaking = nil
            flash("Can\u{2019}t play speech while you\u{2019}re dictating. Try again when you\u{2019}re done.")
        case .failed:
            speaking = nil
            flash(kind == .audio ? "Couldn\u{2019}t play the generated audio." : "Couldn\u{2019}t read the reply aloud.")
        }
    }

    func show(entry id: String) {
        wantedSelection = "id|\(id)"
        if !query.isEmpty { query = "" }
        reload()
    }

    func spokenAudioChanged() { spokenAudioChanges += 1 }

    var selectedSpokenAttempt: SpokenAttempt? { selected?.id.flatMap { spokenAudio?($0) } }

    var selectedSpokenAudio: SpokenAttempt? { selectedSpokenAttempt?.audio == nil ? nil : selectedSpokenAttempt }

    func saveSpokenAudio() {
        guard let attempt = selectedSpokenAudio, let audio = attempt.audio, let folder = chooseSpokenAudioFolder() else { return }
        let base = "Spoken reply \(Self.folderStamp.string(from: attempt.at))"
        var name = base
        var copy = 2
        func files(_ name: String) -> (wav: URL, report: URL) {
            (folder.appendingPathComponent("\(name).wav"), folder.appendingPathComponent("\(name) report.txt"))
        }
        while [files(name).wav, files(name).report].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            name = "\(base) \(copy)"
            copy += 1
        }
        let (wav, report) = files(name)
        var written: [URL] = []
        do {
            try writeFile(audio, wav)
            written.append(wav)
            try writeFile(Data(attempt.report(appName: Branding.appName).utf8), report)
            written.append(report)
            revealInFinder(wav)
            flash("Saved the generated audio and a report, and showed them in Finder.")
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            flash("Couldn\u{2019}t save the generated audio.")
        }
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    static func askForSpokenAudioFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the generated audio and a report about it."
        panel.prompt = "Save Here"
        return panel.runModal() == .OK ? panel.url : nil
    }
    func pasteResult() { if let r = selected?.result, !r.isEmpty { pasteText?(r) } }
    // Likely mishearings of dictionary words in the selected dictation, for the user to judge. A command or a
    // Coding agent message is left out: its words were not dictated text.
    func refreshHints() {
        hintsTask?.cancel()
        hints = []
        guard let entry = selected, !entry.outcome.isCommand, entry.summary == nil, !entry.heard.isEmpty,
              let mishearingHints else { return }
        hintsTask = Task { @MainActor [weak self] in
            let found = await mishearingHints(entry)
            guard let self, !Task.isCancelled, self.selected?.id == entry.id, self.selected?.heard == entry.heard else { return }
            self.hints = found
        }
    }

    func reviewMishearings(_ hint: MishearingHint.Suggestion) {
        let scope: CorrectionDestination.Scope = switch hint.origin {
        case .global: .global
        case .mode(let id): .mode(id)
        case .shared(let id): .shared(id)
        }
        guard mishearings == nil,
              let model = mishearingsFinder?(hint.term, scope, { [weak self] in self?.mishearingsSaved($0) }) else { return }
        mishearings = model
    }

    private func mishearingsSaved(_ count: Int) {
        dismissMishearings()
        flash(count == 1 ? "Added 1 replacement" : "Added \(count) replacements")
        refreshHints()
    }

    var canRewriteSelectedAgain: Bool { rewriteAgain != nil && selected?.canRewriteAgain == true }

    func rewriteSelectedAgain() {
        guard canRewriteSelectedAgain, !rewritingAgain, let entry = selected, let id = entry.id, let rewriteAgain else { return }
        rewritingAgain = true
        rewriteAgainTask = Task { @MainActor [weak self] in
            let outcome = await rewriteAgain(entry)
            guard let self, !Task.isCancelled else { return }
            self.rewritingAgain = false
            switch outcome {
            case .unavailable(let reason):
                self.flash(reason)
            case .rewritten(let text, let details):
                let saved = self.store.update(id: id, near: entry.timestamp) {
                    $0.rewrittenAgain(
                        text, connection: details.connection, model: details.model, redaction: details.redaction,
                        prompt: details.prompt, received: details.received, reasoning: details.reasoning?.summary)
                }
                switch saved {
                case .updated:
                    if self.unsavedRewrite?.id == id { self.unsavedRewrite = nil }
                case .notFound:
                    if self.unsavedRewrite?.id == id { self.unsavedRewrite = nil }
                    self.flash("This dictation was deleted, so its rewrite was not kept.")
                    return
                case .failed:
                    self.unsavedRewrite = (id, text)
                    self.flash("The rewrite could not be saved to History. Use Copy Rewrite to keep it.")
                    return
                }
                self.flash("Rewritten with \(details.connection). Nothing was inserted: copy or paste the result to use it.")
                self.reload()
            }
        }
    }

    var selectedUnsavedRewrite: String? {
        guard let unsavedRewrite, selected?.id == unsavedRewrite.id else { return nil }
        return unsavedRewrite.text
    }

    func copyUnsavedRewrite() { if let text = selectedUnsavedRewrite { copyText?(text) } }

    func copyReport() {
        guard let entry = selected else { return }
        copyText?(SupportReport.render(entry: entry, appName: Branding.appName, setup: supportSetup()))
        flash("Report copied. It includes what you said, any AI request, and any reply update — check it before sending.")
    }

    var voiceCommandsEnabled: () -> Bool = { true }
    var correctsCommands: Bool { selected?.outcome.isCommand == true }
    var canCorrect: Bool { !correctsCommands || voiceCommandsEnabled() }
    private var correctionScope: CorrectionDestination.Scope { correctsCommands ? .mode(Mode.voiceCommandsId) : .global }

    func addDictionaryWord(_ word: String) -> ConfigRepository.AddResult { canCorrect ? saveWord(word, correctionScope) : .failed }
    func analyzeDictionaryWord(_ word: String) -> VocabularyAnalysis { analyzeWord(word, correctionScope) }
    func addReplacement(_ heard: String, _ replace: String) -> ConfigRepository.AddResult {
        canCorrect ? saveReplacement(heard, replace, correctionScope) : .failed
    }

    func saveReplacement(_ heard: String, _ replace: String) -> String? {
        let added = addReplacement(heard, replace)
        guard added == .saved else { return Self.failureMessage(added) }
        refreshHints()
        let target = replace.isEmpty ? "nothing" : ReplacementAuthoring.preview(for: replace).text
        flash("\(correctsCommands ? "Future voice commands" : "Future dictations") will replace \u{201C}\(heard)\u{201D} with \u{201C}\(target)\u{201D}.")
        return nil
    }

    func saveDictionaryWord(_ term: String, _ action: VocabularyAnalysis.Action) -> String? {
        let added = addDictionaryWord(term)
        guard added == .saved else { return Self.failureMessage(added) }
        refreshHints()
        offerMishearings(of: term)
        let destination = correctsCommands
            ? "the Voice Commands dictionary."
            : "your dictionary — a recognition hint for future dictations."
        if case let .updateWord(currentWord) = action {
            flash("Updated \u{201C}\(currentWord)\u{201D} to \u{201C}\(term)\u{201D} in \(destination)")
        } else {
            flash("Added \u{201C}\(term)\u{201D} to \(destination)")
        }
        return nil
    }

    static func failureMessage(_ result: ConfigRepository.AddResult) -> String {
        if case .refused(let message) = result { return message }
        return saveFailedMessage
    }

    func deleteSelected() {
        guard let entry = selected, !rewritingAgain else { return }
        switch store.delete(entry) {
        case .deleted, .notFound:
            if let id = entry.id { forgetSpokenAudio?([id]) }
            if unsavedRewrite?.id == entry.id { unsavedRewrite = nil }
            reload()
        case .writeFailed: flash("Could not delete this entry.")
        }
    }

    static let saveFailedMessage =
        "Couldn't save — a configuration file may be malformed. Open Settings ▸ Maintenance to fix it."

    // The same one step as Vocabulary: a word added from History is checked against History at once, and the
    // finder opens only when it finds likely mishearings.
    // The word is saved from the Add to Dictionary sheet, so the finder waits for that sheet to finish closing:
    // a second sheet presented while the first is still animating out can be dropped, and would then never show.
    private func offerMishearings(of word: String) {
        guard mishearings == nil, foundMishearings == nil,
              let model = mishearingsFinder?(word, correctionScope, { [weak self] in self?.mishearingsSaved($0) })
        else { return }
        model.offeredAfterAdding = true
        dictionarySheetClosed = false
        Task { [weak self] in
            await model.refresh()
            guard let self, self.mishearings == nil, !model.findings.isEmpty else { model.close(); return }
            self.foundMishearings = model
            self.showFoundMishearings()
        }
    }

    func dictionarySheetDidClose() {
        dictionarySheetClosed = true
        showFoundMishearings()
    }

    private func showFoundMishearings() {
        guard dictionarySheetClosed, let found = foundMishearings else { return }
        foundMishearings = nil
        mishearings = found
    }

    func dismissMishearings() {
        mishearings?.close()
        mishearings = nil
    }

    func flash(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            self.statusMessage = nil
        }
    }
}

struct HistoryRetentionChoice: Identifiable, Equatable {
    let days: Int
    let label: String

    var id: Int { days }

    static let presets = [
        HistoryRetentionChoice(days: 1, label: "1 day"),
        HistoryRetentionChoice(days: 3, label: "3 days"),
        HistoryRetentionChoice(days: 7, label: "1 week"),
        HistoryRetentionChoice(days: 14, label: "2 weeks"),
        HistoryRetentionChoice(days: 30, label: "1 month"),
        HistoryRetentionChoice(days: 60, label: "2 months"),
        HistoryRetentionChoice(days: 90, label: "3 months"),
        HistoryRetentionChoice(days: 180, label: "6 months"),
        HistoryRetentionChoice(days: 365, label: "1 year"),
    ]

    static func options(including currentDays: Int) -> [HistoryRetentionChoice] {
        guard !presets.contains(where: { $0.days == currentDays }) else { return presets }
        return (presets + [HistoryRetentionChoice(
            days: currentDays,
            label: displayLabel(for: currentDays)
        )]).sorted { $0.days < $1.days }
    }

    static func displayLabel(for days: Int) -> String {
        presets.first(where: { $0.days == days })?.label
            ?? "\(days) \(days == 1 ? "day" : "days")"
    }

    static func needsConfirmation(
        from currentDays: Int, to newDays: Int, wouldRemoveHistory: Bool
    ) -> Bool {
        newDays < currentDays && wouldRemoveHistory
    }
}

struct HistoryPaneView: View {
    @ObservedObject var model: HistoryPaneModel
    @ObservedObject var settings: SettingsModel
    @State private var pendingRetentionDays: Int?
    // The List selection is mirrored through local @State so SwiftUI's selection write never mutates the
    // ObservableObject during a view update (which logs "Publishing changes from within view updates" and
    // re-enters the backing NSTableView). model.selection is synced in `.onChange`, which runs outside the
    // update pass.
    @State private var selection: HistoryRow.ID?

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: PaneMetrics.listWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(
            "Keep only \(pendingRetentionLabel) of history?",
            isPresented: Binding(
                get: { pendingRetentionDays != nil },
                set: { if !$0 { pendingRetentionDays = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Older Entries", role: .destructive) {
                if let pendingRetentionDays {
                    commitRetention(pendingRetentionDays)
                }
                pendingRetentionDays = nil
            }
            .accessibilityIdentifier(AccessibilityID.History.retentionConfirm)
            Button("Cancel", role: .cancel) { pendingRetentionDays = nil }
                .accessibilityIdentifier(AccessibilityID.History.retentionCancel)
        } message: {
            Text("Dictations older than \(pendingRetentionLabel) will be removed from this Mac. This cannot be undone.")
        }
        .onAppear { selection = model.selection }
        .onChange(of: selection) { _, id in if model.selection != id { model.selection = id } }
        .onChange(of: model.selection) { _, id in if selection != id { selection = id } }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            searchField
            list
            footer
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneListSectionHeader("History")
            SettingRow(
                title: "Keep history on this Mac",
                help: "Stores transcripts and final text locally so you can search and correct them, and coding agent reply updates as they were given. Audio and password-field dictations are never saved. For other sensitive work, choose a shorter period or exclude a mode in its Result handling.",
                combinesAccessibilityChildren: false)
            {
                Toggle("Keep history on this Mac", isOn: $settings.historyEnabled).labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.Settings.General.historyEnabled)
            }
            if settings.historyEnabled {
                LabeledContent("Keep for") {
                    Picker("Keep for", selection: retentionSelection) {
                        ForEach(HistoryRetentionChoice.options(including: settings.retentionDays)) { choice in
                            Text(choice.label).tag(choice.days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.Settings.General.retentionDays)
                }
            }
        }
        .padding(10)
    }

    private var retentionSelection: Binding<Int> {
        Binding(
            get: { settings.retentionDays },
            set: { selectRetention($0) })
    }

    private func selectRetention(_ days: Int) {
        guard days != settings.retentionDays else { return }
        let wouldRemoveHistory = model.wouldRemoveHistory(retainingDays: days)
        if HistoryRetentionChoice.needsConfirmation(
            from: settings.retentionDays, to: days, wouldRemoveHistory: wouldRemoveHistory
        ) {
            pendingRetentionDays = days
        } else {
            commitRetention(days)
        }
    }

    private func commitRetention(_ days: Int) {
        settings.retentionDays = days
        model.applyRetention(days: days)
    }

    private var pendingRetentionLabel: String {
        pendingRetentionDays.map(HistoryRetentionChoice.displayLabel(for:)) ?? "the selected period"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search history", text: $model.query)
                .multilineTextAlignment(.leading)
                .textFieldStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.History.search)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private var list: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasEntries || model.groups.isEmpty {
            Spacer()
        } else {
            List(selection: $selection) {
                ForEach(model.groups, id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.rows) { row in
                            HistoryRowView(entry: row.entry).tag(row.id)
                                .accessibilityIdentifier(AccessibilityID.History.row(row.id))
                        }
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.History.list)
        }
    }

    @ViewBuilder private var detail: some View {
        if !model.hasEntries {
            emptyState
        } else if let entry = model.selected {
            // Keyed by the selected id so switching entries yields a fresh HistoryDetailView with default
            // @State (stage/comparison/text-selection), instead of resetting that @State via
            // `.onChange(of: entry)` — which fired during the selection-driven view update and logged
            // "Modifying state during view update".
            HistoryDetailView(entry: entry, model: model)
                .id(model.selection)
        } else if model.groups.isEmpty {
            ContentUnavailableView(
                "No matching dictations", systemImage: "magnifyingglass",
                description: Text("Try a different search."))
        } else {
            ContentUnavailableView(
                "No dictation selected", systemImage: "clock",
                description: Text("Select an entry to review what was heard, what changed, and what came out."))
        }
    }

    // The single empty state (supersedes phase 5c): the enable toggle above is the affordance, so there is
    // no navigation action here — just a note, and a line naming that history is off when it is.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No dictations yet", systemImage: "clock")
        } description: {
            Text(settings.historyEnabled
                ? "Future dictations appear here."
                : "Future dictations appear here. History is currently off.")
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if model.hasEntries {
                HStack(spacing: 8) {
                    if let line = model.statsLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("Markdown (.md)") { model.export(format: .markdown) }
                        Button("Plain text (.txt)") { model.export(format: .text) }
                        Button("JSON (.jsonl)") { model.export(format: .json) }
                    } label: {
                        Label("Export Results…", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.History.export)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            storageTruth
        }
        .background(.bar)
    }

    private var storageTruth: some View {
        Text("History stays on this Mac. Audio and password-field dictations are never saved. Stored transcripts and final text can still contain sensitive information.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.listText)
                .lineLimit(2).font(.body)
                .foregroundStyle(entry.listTextIsHeard ? .secondary : .primary)
            HStack(spacing: 6) {
                Text(entry.timestamp, style: .time)
                Text("·"); Text(entry.modeName)
                Text("·"); Text(statusLabel(entry))
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(entry.dataBoundaryLabels, id: \.self) { label in
                    DataBoundaryBadge(label: label)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private enum DetailStage: String, CaseIterable, Identifiable {
    case result = "Result"
    case details = "Details"
    var id: String { rawValue }
}

private typealias ComparisonStage = HistoryComparison.Stage

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryPaneModel
    @State private var stage: DetailStage = .result
    @State private var comparisonStage: ComparisonStage = .heardInserted
    @State private var selectedText = ""
    @State private var selectedRole: ComparisonTextRole?
    @State private var showReplacementSheet = false
    @State private var showDictionarySheet = false
    @State private var promptExpanded = false
    @State private var rewriteComparisonExpanded = false
    @State private var receivedExpanded = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionBar
            Picker("", selection: $stage) {
                ForEach(DetailStage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.History.stagePicker)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stageContent
                    if stage != .details, model.canCorrect {
                        Divider()
                        corrections
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            deleteFooter
        }
        .padding(24)
        .confirmationDialog(
            "Delete this dictation?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This dictation will be removed from local history. This cannot be undone.")
        }
        .onChange(of: stage) {
            selectedText = ""
            selectedRole = nil
        }
        .onChange(of: comparisonStage) {
            // Switching the comparison sub-tab swaps the pane texts; clear the seed explicitly rather than
            // relying on the text view's selection-reset side effect (panes that keep identical spans across
            // the switch never rebuild, so they would not fire it).
            selectedText = ""
            selectedRole = nil
        }
        .sheet(isPresented: $showReplacementSheet) {
            CreateReplacementSheet(initialSource: replacementSource, onSave: model.saveReplacement)
        }
        .sheet(isPresented: $showDictionarySheet, onDismiss: { model.dictionarySheetDidClose() }) {
            AddToDictionarySheet(initialTerm: dictionarySource, analyze: { proposal in
                guard case let .word(word) = proposal else {
                    return VocabularyAnalysis(action: .addWord)
                }
                return model.analyzeDictionaryWord(word)
            }, onSave: model.saveDictionaryWord, onCorrect: model.saveReplacement)
        }
        .sheet(item: Binding(get: { model.mishearings }, set: { if $0 == nil { model.dismissMishearings() } })) { finder in
            HistoryReplacementsSheet(model: finder) { model.dismissMishearings() }
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .result: whatHappened
        case .details: details
        }
    }

    private var whatHappened: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = entry.summary {
                actionOutcome(summary)
                if !entry.heard.isEmpty { plainPane("Heard", role: .heard, text: entry.heard) }
                if !entry.result.isEmpty, entry.result != entry.heard {
                    plainPane("Message", role: .result, text: entry.result)
                }
            } else if entry.outcome == .answered {
                plainPane("Request", role: .heard, text: entry.heard)
                mishearingHints
                plainPane("Answer", role: .result, text: entry.result)
            } else {
                comparison
                mishearingHints
            }
            if entry.facts != nil || entry.steps != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What happened").font(.headline)
                    ForEach(Array((entry.facts ?? []).enumerated()), id: \.offset) { _, fact in
                        detailRow(fact.label, fact.value)
                    }
                    ForEach(Array((entry.steps ?? []).enumerated()), id: \.offset) { _, step in
                        detailRow(step.at.formatted(date: .omitted, time: .standard), step.text)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.History.whatHappened)
            }
            if let reply = entry.spokenReply { readAloud(reply) }
            if entry.summary != nil, entry.cloudInvolved {
                DisclosureSection("Compare with the AI rewrite", isExpanded: $rewriteComparisonExpanded) {
                    comparison
                }
                .accessibilityIdentifier(AccessibilityID.History.rewriteComparison)
            }
        }
    }

    @ViewBuilder private var comparison: some View {
        if comparisonStages.count > 1 {
            Picker("", selection: $comparisonStage) {
                ForEach(comparisonStages) { Text(comparisonStageLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.History.comparisonPicker)
        }
        ComparisonSectionView(section: selectedComparisonSection, onSelect: selectComparisonText)
    }

    private func readAloud(_ reply: HistoryEntry.SpokenReply) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reply").font(.headline)
            Text(reply.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            detailRow("From", reply.conversation)
            detailRow("At", reply.at.formatted(date: .omitted, time: .standard))
            if let connection = reply.connection { detailRow("Summarized by", connection) }
            spokenAudio(reply)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.History.spokenReply)
    }

    @ViewBuilder private func spokenAudio(_ reply: HistoryEntry.SpokenReply) -> some View {
        let attempt = model.selectedSpokenAttempt
        if let reader = reply.voice.flatMap(SpokenAttempt.Reader.init(rawValue:)) {
            detailRow("Read by", reader.label.prefix(1).uppercased() + reader.label.dropFirst())
        }
        if let reason = reply.reason ?? attempt?.macOSReason { detailRow("Why", reason.prefix(1).uppercased() + reason.dropFirst()) }
        if let attempt { detailRow("Playback", Self.playback(attempt.playback)) }
        HStack(spacing: 8) {
            if model.speaking == .macOSVoice {
                Button("Stop") { model.stopSpeaking() }
                    .accessibilityIdentifier(AccessibilityID.History.readWithMacOSVoice)
            } else {
                Button("Read with macOS Voice") { model.readReplyWithMacOSVoice() }
                    .accessibilityIdentifier(AccessibilityID.History.readWithMacOSVoice)
            }
            if model.selectedSpokenAudio != nil {
                if model.speaking == .audio {
                    Button("Stop") { model.stopSpeaking() }
                        .accessibilityIdentifier(AccessibilityID.History.playSpokenAudio)
                } else {
                    Button("Play Generated Audio") { model.playSpokenAudio() }
                        .disabled(!model.canPlaySpokenAudio)
                        .help(model.canPlaySpokenAudio ? "" : "This reply is still being read aloud.")
                        .accessibilityIdentifier(AccessibilityID.History.playSpokenAudio)
                }
                Button("Save Generated Audio\u{2026}") { model.saveSpokenAudio() }
                    .accessibilityIdentifier(AccessibilityID.History.saveSpokenAudio)
            }
        }
        if let held = model.selectedSpokenAudio {
            Text(Self.heldAudioCaption(held))
                .font(.caption).foregroundStyle(.secondary)
        } else if reply.voice.flatMap(SpokenAttempt.Reader.init(rawValue:)) == .natural {
            Text("The original audio is no longer available.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func heldAudioCaption(_ held: SpokenAttempt) -> String {
        let kept = "The audio \(Branding.appName) generated for this reply is kept for an hour while \(Branding.appName) is running."
        guard held.reader != .macOS else {
            return kept + " It is the natural voice\u{2019}s audio that was not played; the macOS voice read the reply."
        }
        return kept + " Play it to hear the audio \(Branding.appName) generated, or save it to report a reply that sounded wrong."
    }

    private static func playback(_ playback: SpokenAttempt.Playback) -> String {
        switch playback {
        case .preparing: "Not started"
        case .playing: "Playing"
        case .finished: "Played to the end"
        case .interrupted: "Stopped before the end"
        case .failed: "Failed"
        }
    }

    private var mishearingHints: some View {
        ForEach(model.hints, id: \.term) { hint in
            HStack(spacing: 8) {
                Text("\u{201C}\(hint.phrase)\u{201D} may be \u{201C}\(hint.term)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Review Mishearings\u{2026}") { model.reviewMishearings(hint) }
                    .controlSize(.small)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.History.mishearingHint)
        }
    }

    private func plainPane(_ title: String, role: ComparisonTextRole, text: String) -> some View {
        ComparisonPane(title: title, role: role, spans: [.init(id: 0, text: text, kind: .unchanged)], onSelect: selectComparisonText)
    }

    @ViewBuilder private func actionOutcome(_ summary: String) -> some View {
        Group {
            if entry.outcome == .failed {
                IssueText(summary, font: .title3)
            } else {
                Text(summary).font(.title3)
            }
        }
        .accessibilityIdentifier(AccessibilityID.History.actionOutcome)
    }

    private func selectComparisonText(_ role: ComparisonTextRole, _ text: String) {
        selectedRole = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : role
        selectedText = text
    }

    private var comparisonStages: [ComparisonStage] {
        HistoryComparison.stages(cloudInvolved: entry.cloudInvolved)
    }

    private var selectedComparisonSection: ComparisonSection {
        let available = Set(comparisonStages)
        let selected = available.contains(comparisonStage) ? comparisonStage : .heardInserted
        // onThisMac/rewrite only appear when a cloud rewrite was involved (see HistoryComparison.stages),
        // so those stages always use the cloud wording.
        let texts = HistoryComparison.texts(
            for: selected, heard: entry.heard, transformed: entry.transformed, result: entry.result)
        switch selected {
        case .heardInserted:
            let to = resultTitle
            return ComparisonSection(
                id: "heard-inserted",
                title: "Heard -> \(to)",
                context: entry.cloudInvolved ? "Includes AI rewrite" : "No cloud rewrite",
                from: .init(title: "Heard", role: .heard, text: texts.from),
                to: .init(title: to, role: .result, text: texts.to))
        case .onThisMac:
            return ComparisonSection(
                id: "on-this-mac",
                title: "On this Mac",
                context: "Before any cloud rewrite",
                from: .init(title: "Heard", role: .heard, text: texts.from),
                to: .init(title: "Before rewrite", role: .local, text: texts.to))
        case .rewrite:
            return ComparisonSection(
                id: "rewrite",
                title: "AI rewrite",
                context: rewriteContext,
                from: .init(title: "Before rewrite", role: .local, text: texts.from),
                to: .init(title: resultTitle, role: .result, text: texts.to))
        }
    }

    private var resultTitle: String {
        if entry.outcome.isCommand { return "Command" }
        return entry.summary == nil && entry.outcome != .rewrittenLater ? "Inserted" : "Result"
    }

    private var rewriteContext: String {
        if let connection = entry.connection {
            return "Sent to \(connection) for rewrite"
        }
        return "Sent to an AI service for rewrite"
    }

    private func comparisonStageLabel(_ stage: ComparisonStage) -> String {
        switch stage {
        case .heardInserted: "Heard -> \(resultTitle)"
        case .onThisMac: "On this Mac"
        case .rewrite: "AI rewrite"
        }
    }

    private var selectionIsHeard: Bool { selectedRole == .heard }

    private var replacementSource: String {
        HistoryCorrectionSource.replacement(selection: selectedText, selectionIsHeard: selectionIsHeard)
    }

    private var dictionarySource: String {
        HistoryCorrectionSource.dictionary(
            selection: selectedText, selectionIsHeard: selectionIsHeard, result: entry.result)
    }

    private var header: some View {
        PaneDetailHeader(
            systemImage: "clock",
            symbolStyle: AnyShapeStyle(.secondary),
            title: entry.modeName,
            badges: {
                if entry.summary == nil { PaneBadge(outcomeLabel(entry)) }
                ForEach(entry.dataBoundaryLabels, id: \.self) { DataBoundaryBadge(label: $0) }
            },
            trailing: {
                Text(entry.timestamp, style: .time).foregroundStyle(.secondary).font(.caption)
            })
    }

    private var canReuseResult: Bool { !entry.result.isEmpty }
    private var canCopyHeard: Bool { !entry.heard.isEmpty && entry.heard != entry.result }

    private var actionBar: some View {
        WrapLayout(spacing: 8) {
            if !entry.isSpokenReplyOnly {
                Button { model.copyResult() } label: { Label("Copy Result", systemImage: "doc.on.doc") }
                    .disabled(!canReuseResult)
                    .accessibilityIdentifier(AccessibilityID.History.copyResult)
            }
            if entry.spokenReply != nil {
                Button { model.copyReply() } label: { Label("Copy Reply", systemImage: "speaker.wave.2") }
                    .accessibilityIdentifier(AccessibilityID.History.copyReply)
            }
            if !entry.outcome.isCommand {
                Button { model.pasteResult() } label: { Label("Paste Result", systemImage: "arrow.down.doc") }
                    .disabled(!canReuseResult)
                    .accessibilityIdentifier(AccessibilityID.History.pasteResult)
            }
            if canCopyHeard {
                Button { model.copyHeard() } label: { Label("Copy Heard", systemImage: "text.quote") }
                    .accessibilityIdentifier(AccessibilityID.History.copyHeard)
            }
            if model.canRewriteSelectedAgain {
                Button { model.rewriteSelectedAgain() } label: { Label("Rewrite Again", systemImage: "arrow.clockwise") }
                    .disabled(model.rewritingAgain)
                    .help("Runs the AI rewrite again on what was heard, with this mode as it is now. Nothing from the screen is sent, and nothing is inserted: the new text replaces this dictation's result.")
                    .accessibilityIdentifier(AccessibilityID.History.rewriteAgain)
                if model.rewritingAgain { ProgressView().controlSize(.small) }
            }
            if model.selectedUnsavedRewrite != nil {
                Button { model.copyUnsavedRewrite() } label: { Label("Copy Rewrite", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier(AccessibilityID.History.copyUnsavedRewrite)
            }
            if !entry.isSpokenReplyOnly {
                Button { model.copyReport() } label: { Label("Copy Report", systemImage: "ladybug") }
                    .help("Copies this dictation for a bug report: what you said, the inserted text, the app it was for, your microphone's name, any AI request and reply (which can include your dictionary words, selected text, or text from the app), a coding agent's reply update, and details about your setup.")
                    .accessibilityIdentifier(AccessibilityID.History.copyReport)
            }
        }
    }

    private var deleteFooter: some View {
        HStack(spacing: 12) {
            Text(model.statusMessage ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PaneDeleteButton(title: "Delete Dictation") { confirmingDelete = true }
                .disabled(model.rewritingAgain)
                .accessibilityIdentifier(AccessibilityID.History.delete)
        }
    }

    private var corrections: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Corrections").font(.headline)
                Spacer()
                Button { model.openSettings(.vocabulary) } label: {
                    Label("Manage Vocabulary…", systemImage: "text.book.closed")
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier(AccessibilityID.History.manageVocabulary)
            }
            HStack {
                Button("Create Replacement…") { showReplacementSheet = true }
                    .accessibilityIdentifier(AccessibilityID.History.createReplacement)
                Button("Add to Dictionary…") { showDictionarySheet = true }
                    .accessibilityIdentifier(AccessibilityID.History.addToDictionary)
            }
            Text(correctionHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var correctionHint: String {
        let box = entry.outcome == .answered ? "Request" : "Heard"
        switch HistoryCorrectionSource.hint(selection: selectedText, selectionIsHeard: selectionIsHeard) {
        case .selectFirst:
            return "Select words in a \(box) box first, so the correction targets just that phrase."
        case .usingHeard(let phrase):
            return "Using your \(box) selection \u{201C}\(phrase)\u{201D}."
        case .selectHeard:
            return "Select words in a \(box) box to create a replacement or dictionary hint."
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Privacy & processing").font(.headline)
                if let howChosen = ModeChoiceLine.text(
                    reason: entry.modeChoice, routedPhrase: entry.routedPhrase, triggerDisplay: entry.triggerKey) {
                    detailRow("How chosen", howChosen)
                }
                detailRow(entry.outcome == .answered ? "AI answer" : "AI rewrite", rewriteSummary)
                if let reasoning = entry.reasoning {
                    detailRow("Reasoning", reasoning)
                }
                if entry.stoppedAtLimit == true {
                    detailRow("Recording", "Stopped at the time limit")
                }
                if let why = whyLocalWasKept(entry) {
                    detailRow("Why local was kept", why)
                }
                if let reason = entry.failureReason {
                    detailRow("Why it failed", reason)
                }
                if let reported = entry.reported {
                    detailRow("Reported", reported)
                }
                detailRow("Best-effort redaction", entry.redaction ? "Applied" : "Not applied")
                detailRow("Speech", entry.engine.map { "On-device · \($0)" } ?? "On-device")
                if let device = entry.device {
                    detailRow("Input device", device)
                }
                detailRow("Context sent", entry.contextLabels.isEmpty ? "None" : entry.contextLabels.joined(separator: ", "))
            }
            if let prompt = entry.prompt {
                DisclosureSection("Show exactly what was sent", isExpanded: $promptExpanded) {
                    rawExchangeText(prompt)
                }
                .accessibilityIdentifier(AccessibilityID.History.promptDisclosure)
            }
            if let received = entry.received {
                DisclosureSection("Show exactly what was received", isExpanded: $receivedExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        if showsUnusedReplyNote(entry) {
                            Text("This reply was not used — your local text was kept.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        rawExchangeText(received)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.History.receivedDisclosure)
            }
            Text("Redaction maps are never shown or stored.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var rewriteSummary: String {
        guard let connection = entry.connection else { return "None — local only" }
        let where_ = entry.cloudInvolved ? "cloud" : "local"
        return connection + (entry.model.map { " · \($0)" } ?? "") + " · \(where_)"
    }

    private func rawExchangeText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).font(.caption)
        }
    }
}

func whyLocalWasKept(_ entry: HistoryEntry) -> String? {
    if let skipped = entry.rewriteSkippedMs { return HUDState.skippedLine(Double(skipped) / 1000) }
    return entry.keptLocalText ? entry.fallbackReason : nil
}

func showsUnusedReplyNote(_ entry: HistoryEntry) -> Bool {
    entry.keptLocalText && entry.received != nil
}

func statusLabel(_ entry: HistoryEntry) -> String {
    entry.summary ?? outcomeLabel(entry)
}

func outcomeLabel(_ entry: HistoryEntry) -> String {
    if entry.outcome == .localFallback, entry.rewriteSkippedMs != nil { return "Rewrite skipped" }
    return switch entry.outcome {
    case .inserted: "Inserted"
    case .copied: "Copied instead of inserted"
    case .localFallback: "Local fallback"
    case .failed: "Failed"
    case .command: "Command"
    case .commandFailed: "Command failed"
    case .commandStarted: "Command started"
    case .commandNeedsChoice: "Needs a choice"
    case .commandCancelled: "Choice cancelled"
    case .rewrittenLater: "Rewritten later, not inserted"
    case .answered: "Answered"
    }
}
