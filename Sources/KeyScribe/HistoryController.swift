import AppKit
import KeyScribeKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HistoryController {
    private var window: NSWindow?
    private let model: HistoryViewModel
    private var loadedSignature: String?
    // The app to hand focus back to for a "Paste Result", since History itself is key while the user
    // reads. Seeded from the frontmost app at open and kept fresh while the window is up: the user can
    // switch to another app and back before pasting, so the target must track the last real app they
    // were in, not the one frontmost when History was first presented.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init(
        store: HistoryStore,
        addDictionaryWord: @escaping (String) -> Void,
        addReplacement: @escaping (String, String) -> Void,
        openSettings: @escaping (SettingsDestination) -> Void
    ) {
        model = HistoryViewModel(
            store: store, addDictionaryWord: addDictionaryWord,
            addReplacement: addReplacement, openSettings: openSettings)
        model.copyText = { TextInserter.copyToClipboard($0) }
        model.pasteText = { [weak self] in self?.pasteToPreviousApp($0) }
    }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        // Re-parsing the JSONL on every open is wasteful when nothing has changed since the last load;
        // the store's cheap signature gates the reload so re-fronting the window is free.
        let signature = model.storeSignature()
        if window == nil || signature != loadedSignature {
            model.reload()
            loadedSignature = signature
        }
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: HistoryView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "History"
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 820, height: 520)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1040, height: 720)
        window.setContentSize(NSSize(width: min(1040, max(820, visible.width - 80)),
                                     height: min(720, max(520, visible.height - 80))))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        observeLifecycle(of: window)
    }

    private func observeLifecycle(of window: NSWindow) {
        let selfBundleId = Bundle.main.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true,
                      let app = NSWorkspace.shared.frontmostApplication,
                      app.bundleIdentifier != selfBundleId else { return }
                self.previousApp = app
            }
        }
        // The window is not released on close, so its parsed rows + full-store cache would otherwise
        // survive until the next open; drop them and force a fresh read next present().
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.releaseForClose()
                self.loadedSignature = nil
            }
        }
    }

    // Paste lands in the frontmost app, but History is key while open, so we hand focus back to the
    // app the user was last in and paste there via the shared safe insertion path.
    // No reliable target (History is the only candidate, or nothing was frontmost) → copy instead and
    // say so, rather than synthesize a ⌘V into ourselves.
    private func pasteToPreviousApp(_ text: String) {
        guard let target = previousApp,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            TextInserter.copyToClipboard(text)
            model.flash("No target app to paste into — copied to clipboard instead.")
            return
        }
        window?.orderOut(nil)
        Task { @MainActor in
            guard await TextInserter.pasteReturning(to: target, text: text) else {
                TextInserter.copyToClipboard(text)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                model.flash("Could not return to the app — copied to clipboard instead.")
                return
            }
        }
    }
}

private struct HistoryRow: Identifiable, Sendable {
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
private final class HistoryViewModel: ObservableObject {
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
    let addDictionaryWord: (String) -> Void
    let addReplacement: (String, String) -> Void
    let openSettings: (SettingsDestination) -> Void
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
        addDictionaryWord: @escaping (String) -> Void,
        addReplacement: @escaping (String, String) -> Void,
        openSettings: @escaping (SettingsDestination) -> Void
    ) {
        self.store = store
        self.addDictionaryWord = addDictionaryWord
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
        entryIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.entry) })
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
        groups = Dictionary(grouping: filtered, by: \.day)
            .map { (day: $0.key, rows: $0.value) }
            .sorted { ($0.rows.first?.entry.timestamp ?? .distantPast) > ($1.rows.first?.entry.timestamp ?? .distantPast) }
        resolveSelection()
    }

    // Keep a still-present selection (so a background reload or search refinement does not yank the
    // user off what they were reading), otherwise fall to the newest visible row — which also makes the
    // newest dictation the default first glance and picks the first match when a search drops the old one.
    // The auto-pick is deferred a tick: a List resets a selection assigned before its rows are in the
    // view tree (the initial load sets it behind the loading spinner), so we wait for the rows to commit.
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

private struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel

    var body: some View {
        NavigationSplitView {
            Group {
                if model.isLoading {
                    ProgressView("Loading history…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.hasEntries {
                    ContentUnavailableView {
                        Label("No dictations yet", systemImage: "clock")
                    } description: {
                        Text("Future dictations appear here when history is enabled.")
                    } actions: {
                        Button("Open History Settings") { model.openSettings(.general) }
                    }
                } else if model.groups.isEmpty {
                    ContentUnavailableView(
                        "No matching dictations", systemImage: "magnifyingglass",
                        description: Text("Try a different search."))
                } else {
                    List(selection: $model.selection) {
                        ForEach(model.groups, id: \.day) { group in
                            Section(group.day) {
                                ForEach(group.rows) { row in
                                    HistoryRowView(entry: row.entry).tag(row.id)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search history")
            .frame(minWidth: 280)
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            if let entry = model.selected {
                HistoryDetailView(entry: entry, model: model)
            } else {
                ContentUnavailableView(
                    "No dictation selected", systemImage: "clock",
                    description: Text("Select an entry to review what was heard, what changed, and what came out."))
            }
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            storageTruth
        }
        .background(.thinMaterial)
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
    case whatHappened = "What Happened"
    case details = "Details"
    var id: String { rawValue }
}

private typealias ComparisonStage = HistoryComparison.Stage

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryViewModel
    @State private var stage: DetailStage = .whatHappened
    @State private var comparisonStage: ComparisonStage = .heardInserted
    @State private var selectedText = ""
    @State private var selectedRole: ComparisonTextRole?
    @State private var showReplacementSheet = false
    @State private var showDictionarySheet = false
    @State private var promptExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionBar
            Picker("", selection: $stage) {
                ForEach(DetailStage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        }
        .padding(24)
        .onChange(of: entry.timestamp) {
            selectedText = ""
            selectedRole = nil
            stage = .whatHappened
            comparisonStage = .heardInserted
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
                model.addReplacement(heard, replace)
                model.flash("Future dictations will replace \u{201C}\(heard)\u{201D} with \u{201C}\(replace.isEmpty ? "nothing" : replace)\u{201D}.")
            }
        }
        .sheet(isPresented: $showDictionarySheet) {
            AddToDictionarySheet(initialTerm: dictionarySource) { term in
                model.addDictionaryWord(term)
                model.flash("Added \u{201C}\(term)\u{201D} to your dictionary — a recognition hint for future dictations.")
            }
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .whatHappened: whatHappened
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
        HStack(spacing: 8) {
            Text(entry.modeName).font(.headline)
            badge(outcomeLabel(entry.outcome))
            ForEach(entry.dataBoundaryLabels, id: \.self) { DataBoundaryBadge(label: $0) }
            Spacer()
            Text(entry.timestamp, style: .time).foregroundStyle(.secondary).font(.caption)
        }
    }

    private var canReuseResult: Bool { !entry.result.isEmpty }
    private var canCopyHeard: Bool { !entry.heard.isEmpty && entry.heard != entry.result }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { model.copyResult() } label: { Label("Copy Result", systemImage: "doc.on.doc") }
                .disabled(!canReuseResult)
            Button { model.pasteResult() } label: { Label("Paste Result", systemImage: "arrow.down.doc") }
                .disabled(!canReuseResult)
            if canCopyHeard {
                Button { model.copyHeard() } label: { Label("Copy Heard", systemImage: "text.quote") }
            }
            Spacer()
            if let message = model.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { model.deleteSelected() } label: {
                Label("Delete", systemImage: "trash")
            }
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
            }
            HStack {
                Button("Create Replacement…") { showReplacementSheet = true }
                Button("Add to Dictionary…") { showDictionarySheet = true }
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
                detailRow("AI rewrite", rewriteSummary)
                detailRow("Best-effort redaction", entry.redaction ? "Applied" : "Not applied")
                detailRow("Speech", entry.engine.map { "On-device · \($0)" } ?? "On-device")
                detailRow("Context sent", entry.contextLabels.isEmpty ? "None" : entry.contextLabels.joined(separator: ", "))
            }
            if let prompt = entry.prompt {
                DisclosureSection("Show exactly what was sent", isExpanded: $promptExpanded) {
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
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

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).font(.caption)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
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
