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
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(entry.modeName)\u{1F}\(entry.heard)\u{1F}\(entry.result)\u{1F}\(entry.outcome.rawValue)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(entry.timestamp.timeIntervalSince1970)|\(hash)"
    }
}

@MainActor
final class HistoryPaneModel: ObservableObject {
    @Published var query = "" { didSet { scheduleRecompute() } }
    @Published var selection: HistoryRow.ID?
    @Published private(set) var groups: [(day: String, rows: [HistoryRow])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statsLine: String?

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
    let addDictionaryWord: (String) -> Bool
    let analyzeDictionaryWord: (String) -> VocabularyAnalysis
    let addReplacement: (String, String) -> Bool
    var openSettings: (SettingsDestination) -> Void
    var copyText: ((String) -> Void)?
    var pasteText: ((String) -> Void)?

    // Shared across the main-actor load path and the detached search task; `nonisolated` opts out of the
    // enclosing @MainActor isolation the detached task cannot satisfy (DateFormatter is Sendable and
    // thread-safe for formatting once configured).
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    init(
        store: HistoryStore,
        addDictionaryWord: @escaping (String) -> Bool,
        analyzeDictionaryWord: @escaping (String) -> VocabularyAnalysis,
        addReplacement: @escaping (String, String) -> Bool,
        openSettings: @escaping (SettingsDestination) -> Void
    ) {
        self.store = store
        self.addDictionaryWord = addDictionaryWord
        self.analyzeDictionaryWord = analyzeDictionaryWord
        self.addReplacement = addReplacement
        self.openSettings = openSettings
    }

    func storeSignature() -> String { store.signature() }

    // Drop everything held for the visible window so a closed History window retains no parsed
    // transcripts or the full-store search cache; the next open re-reads from disk.
    func releaseForClose() {
        loadGeneration &+= 1
        recomputeTask?.cancel(); searchTask?.cancel(); statusTask?.cancel()
        selectionTask?.cancel(); reloadTask?.cancel()
        rows = []
        entryIndex = [:]
        searchCache = nil
        groups = []
        selection = nil
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
            guard let self, !Task.isCancelled else { return }
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
        if let selection, visible.contains(selection) { return }
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
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
    func pasteResult() { if let r = selected?.result, !r.isEmpty { pasteText?(r) } }

    func deleteSelected() {
        guard let entry = selected else { return }
        switch store.delete(entry) {
        case .deleted, .notFound: reload()
        case .writeFailed: flash("Could not delete this entry.")
        }
    }

    static let saveFailedMessage =
        "Couldn't save — a configuration file may be malformed. Open Settings ▸ Maintenance to fix it."

    func flash(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.statusMessage = nil
        }
    }
}

// History is a Settings pane, not a window: the Modes-style HStack list/detail, with the
// enable/retention controls (moved out of General) inline above the list and the storage-truth statement
// pinned at the bottom. Reload/release lifecycle is driven by SettingsRootView on pane selection.
struct HistoryPaneView: View {
    @ObservedObject var model: HistoryPaneModel
    @ObservedObject var settings: SettingsModel
    @State private var retentionDays: Int?
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
            "Remove older dictation history?",
            isPresented: Binding(
                get: { pendingRetentionDays != nil },
                set: { if !$0 { pendingRetentionDays = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Entries", role: .destructive) {
                if let pendingRetentionDays {
                    settings.retentionDays = pendingRetentionDays
                    model.applyRetention(days: pendingRetentionDays)
                }
                pendingRetentionDays = nil
                retentionDays = nil
            }
            Button("Cancel", role: .cancel) { pendingRetentionDays = nil }
        } message: {
            Text("Entries older than the new retention period will be removed. This cannot be undone.")
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
        SettingRow(
            title: "History",
            result: settings.historyEnabled
                ? "On this Mac · keep for \(settings.retentionDays) days"
                : "Off",
            help: "Stores transcripts and final text locally so you can search and correct them. Audio and password-field dictations are never saved. For other sensitive work, lower retention or exclude a mode in its Result handling.")
        {
            HStack(spacing: 8) {
                if settings.historyEnabled {
                    Stepper("\(retentionDays ?? settings.retentionDays) days", value: retentionDraft, in: 1...365)
                        .accessibilityIdentifier(AccessibilityID.Settings.General.retentionDays)
                    if retentionDays != nil {
                        Button("Apply", action: applyRetention)
                    }
                }
                Toggle("Keep history", isOn: $settings.historyEnabled).labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.Settings.General.historyEnabled)
            }
        }
        .padding(10)
    }

    private var retentionDraft: Binding<Int> {
        Binding(
            get: { retentionDays ?? settings.retentionDays },
            set: { retentionDays = $0 })
    }

    private func applyRetention() {
        guard let retentionDays else { return }
        if retentionDays < settings.retentionDays, model.wouldRemoveHistory(retainingDays: retentionDays) {
            pendingRetentionDays = retentionDays
        } else {
            settings.retentionDays = retentionDays
            model.applyRetention(days: retentionDays)
            self.retentionDays = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search history", text: $model.query)
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
            Text(entry.result.isEmpty ? "(no text)" : entry.result)
                .lineLimit(2).font(.body)
            HStack(spacing: 6) {
                Text(entry.timestamp, style: .time)
                Text("·"); Text(entry.modeName)
                Text("·"); Text(outcomeLabel(entry.outcome))
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
                    if stage != .details {
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
            CreateReplacementSheet(initialSource: replacementSource) { heard, replace in
                if model.addReplacement(heard, replace) {
                    model.flash("Future dictations will replace \u{201C}\(heard)\u{201D} with \u{201C}\(replace.isEmpty ? "nothing" : replace)\u{201D}.")
                } else {
                    model.flash(HistoryPaneModel.saveFailedMessage)
                }
            }
        }
        .sheet(isPresented: $showDictionarySheet) {
            AddToDictionarySheet(initialTerm: dictionarySource, analyze: { proposal in
                guard case let .word(word) = proposal else {
                    return VocabularyAnalysis(action: .addWord)
                }
                return model.analyzeDictionaryWord(word)
            }) { term, action in
                if model.addDictionaryWord(term) {
                    if case let .updateWord(currentWord) = action {
                        model.flash("Updated \u{201C}\(currentWord)\u{201D} to \u{201C}\(term)\u{201D} in your dictionary — a recognition hint for future dictations.")
                    } else {
                        model.flash("Added \u{201C}\(term)\u{201D} to your dictionary — a recognition hint for future dictations.")
                    }
                } else {
                    model.flash(HistoryPaneModel.saveFailedMessage)
                }
            }
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
            if comparisonStages.count > 1 {
                Picker("", selection: $comparisonStage) {
                    ForEach(comparisonStages) { Text(comparisonStageLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.History.comparisonPicker)
            }
            ComparisonSectionView(section: selectedComparisonSection) { role, text in
                selectedRole = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : role
                selectedText = text
            }
        }
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
            return ComparisonSection(
                id: "heard-inserted",
                title: "Heard -> Inserted",
                context: entry.cloudInvolved ? "Includes AI rewrite" : "No cloud rewrite",
                from: .init(title: "Heard", role: .heard, text: texts.from),
                to: .init(title: "Inserted", role: .result, text: texts.to))
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
                to: .init(title: "Inserted", role: .result, text: texts.to))
        }
    }

    private var rewriteContext: String {
        if let connection = entry.connection {
            return "Sent to \(connection) for rewrite"
        }
        return "Sent to an AI service for rewrite"
    }

    private func comparisonStageLabel(_ stage: ComparisonStage) -> String {
        switch stage {
        case .heardInserted: "Heard -> Inserted"
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
                PaneBadge(outcomeLabel(entry.outcome))
                ForEach(entry.dataBoundaryLabels, id: \.self) { DataBoundaryBadge(label: $0) }
            },
            trailing: {
                Text(entry.timestamp, style: .time).foregroundStyle(.secondary).font(.caption)
            })
    }

    private var canReuseResult: Bool { !entry.result.isEmpty }
    private var canCopyHeard: Bool { !entry.heard.isEmpty && entry.heard != entry.result }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { model.copyResult() } label: { Label("Copy Result", systemImage: "doc.on.doc") }
                .disabled(!canReuseResult)
                .accessibilityIdentifier(AccessibilityID.History.copyResult)
            Button { model.pasteResult() } label: { Label("Paste Result", systemImage: "arrow.down.doc") }
                .disabled(!canReuseResult)
                .accessibilityIdentifier(AccessibilityID.History.pasteResult)
            if canCopyHeard {
                Button { model.copyHeard() } label: { Label("Copy Heard", systemImage: "text.quote") }
                    .accessibilityIdentifier(AccessibilityID.History.copyHeard)
            }
            Spacer()
            if let message = model.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deleteFooter: some View {
        HStack {
            Spacer()
            PaneDeleteButton(title: "Delete Dictation") { confirmingDelete = true }
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
        switch HistoryCorrectionSource.hint(selection: selectedText, selectionIsHeard: selectionIsHeard) {
        case .selectFirst:
            return "Select words in a Heard box first, so the correction targets just that phrase."
        case .usingHeard(let phrase):
            return "Using your Heard selection \u{201C}\(phrase)\u{201D}."
        case .selectHeard:
            return "Select words in a Heard box to create a replacement or dictionary hint."
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
                detailRow("AI rewrite", rewriteSummary)
                if entry.outcome == .localFallback, let reason = entry.fallbackReason {
                    detailRow("Why local was kept", reason)
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
                        if entry.outcome == .localFallback {
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

private func outcomeLabel(_ outcome: HistoryEntry.Outcome) -> String {
    switch outcome {
    case .inserted: "Inserted"
    case .copied: "Copied instead of inserted"
    case .localFallback: "Local fallback"
    case .failed: "Failed"
    }
}
