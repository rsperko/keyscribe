import AppKit
import KeyScribeKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HistoryController {
    private var window: NSWindow?
    private let model: HistoryViewModel
    private var loadedSignature: String?
    // The app that was frontmost when History opened — the target a "Paste Result" must land in,
    // since History itself is key while the user is reading.
    private var previousApp: NSRunningApplication?

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
    }

    // Paste lands in the frontmost app, but History is key while open, so we hand focus back to the
    // app that was frontmost when History opened and paste there via the shared safe insertion path.
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
        target.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            await TextInserter.insertViaPaste(text)
        }
    }
}

private struct HistoryRow: Identifiable {
    let id = UUID()
    let entry: HistoryEntry
    let day: String
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
    private var recomputeTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    private let store: HistoryStore
    let addDictionaryWord: (String) -> Void
    let addReplacement: (String, String) -> Void
    let openSettings: (SettingsDestination) -> Void
    var copyText: ((String) -> Void)?
    var pasteText: ((String) -> Void)?

    private let dayFormatter: DateFormatter = {
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

    func reload() {
        isLoading = true
        let store = self.store
        let limit = Self.loadLimit
        reloadTask?.cancel()
        reloadTask = Task.detached { [weak self] in
            let loaded = store.entries(limit: limit)
            if Task.isCancelled { return }
            await self?.applyLoaded(loaded)
        }
    }

    private func applyLoaded(_ loaded: [HistoryEntry]) {
        rows = loaded.map { HistoryRow(entry: $0, day: dayFormatter.string(from: $0.timestamp)) }
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
                return HistoryExport.export(filtered, format: format, formatting: formatting)
            }.value
            self.presentSavePanel(payload: payload, format: format)
        }
    }

    private func presentSavePanel(payload: String, format: HistoryExport.Format) {
        guard !payload.isEmpty else { flash("Nothing to export."); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "keyscribe-history.\(format.fileExtension)"
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
        recomputeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.recomputeGroups()
        }
    }

    private func recomputeGroups() {
        let filtered = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rows
            : rows.filter { HistorySearch.matches($0.entry, query: query) }
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
        _ = store.delete(entry)
        reload()
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

private enum ComparisonTextRole {
    case heard
    case local
    case result
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

private struct ComparisonSection: Identifiable {
    struct Side {
        let title: String
        let role: ComparisonTextRole
        let text: String
    }

    let id: String
    let title: String
    let context: String
    let from: Side
    let to: Side
}

// One source of truth for diff styling so the text rendering and the legend never diverge. Meaning is
// never carried by color alone (ui_components.md §semantic colors): each changed kind also gets a
// background tint and a typographic mark, so removed/added/changed stay distinguishable in grayscale
// and for color-vision deficiency. Unchanged text recedes (secondary) so edits are what stand out.
private enum DiffStyle {
    static func foreground(_ kind: TextComparison.Span.Kind) -> NSColor {
        switch kind {
        case .unchanged, .formatting: return .secondaryLabelColor
        case .removed: return .systemRed
        case .added: return .systemGreen
        case .changed: return .systemOrange
        }
    }

    static func background(_ kind: TextComparison.Span.Kind) -> NSColor? {
        switch kind {
        case .unchanged: return nil
        case .formatting: return NSColor.secondaryLabelColor.withAlphaComponent(0.14)
        case .removed: return NSColor.systemRed.withAlphaComponent(0.14)
        case .added: return NSColor.systemGreen.withAlphaComponent(0.14)
        case .changed: return NSColor.systemOrange.withAlphaComponent(0.16)
        }
    }

    enum Mark { case none, strikethrough, underline }
    static func mark(_ kind: TextComparison.Span.Kind) -> Mark {
        switch kind {
        case .unchanged, .formatting: return .none
        case .removed: return .strikethrough
        case .added, .changed: return .underline
        }
    }

    static func label(_ kind: TextComparison.Span.Kind) -> String {
        switch kind {
        case .unchanged: return "Unchanged"
        case .formatting: return "Formatting"
        case .removed: return "Removed"
        case .added: return "Added"
        case .changed: return "Changed"
        }
    }

    // Legend chips read as a key, so they use the solid foreground hue rather than the faint in-text tint.
    static func swatch(_ kind: TextComparison.Span.Kind) -> NSColor { foreground(kind) }

    static let legendOrder: [TextComparison.Span.Kind] = [.removed, .added, .changed, .formatting]
}

private struct ComparisonSectionView: View {
    let section: ComparisonSection
    let onSelect: (ComparisonTextRole, String) -> Void

    var body: some View {
        // Compute the diff once per render — it is O(n·m) and was previously recomputed for each of
        // status, left, and right on every body evaluation (including the user's own text selection).
        let comparison = TextComparison.compare(section.from.text, section.to.text)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title).font(.headline)
                Spacer()
                Text(status(comparison.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(section.context)
                .font(.caption)
                .foregroundStyle(.secondary)
            ComparisonPane(
                title: section.from.title,
                role: section.from.role,
                spans: comparison.left,
                onSelect: onSelect)
            ComparisonPane(
                title: section.to.title,
                role: section.to.role,
                spans: comparison.right,
                onSelect: onSelect)
            DiffLegend(kinds: legendKinds(comparison))
        }
    }

    private func status(_ summary: TextComparison.Summary) -> String {
        switch summary {
        case .identical: return "No differences"
        case .formattingOnly: return "Only formatting changed"
        case .substitution(let from, let to): return "Changed \u{201C}\(from)\u{201D} \u{2192} \u{201C}\(to)\u{201D}"
        case .counts(let removed, let added, let changed):
            var parts: [String] = []
            if changed > 0 { parts.append("\(changed) changed") }
            if added > 0 { parts.append("\(added) added") }
            if removed > 0 { parts.append("\(removed) removed") }
            return parts.joined(separator: " \u{00B7} ")
        case .tooLongToCompare:
            return "Text changed \u{2014} too long to compare in detail"
        }
    }

    private func legendKinds(_ comparison: TextComparison) -> [TextComparison.Span.Kind] {
        let present = Set(comparison.left.map(\.kind)).union(comparison.right.map(\.kind))
        return DiffStyle.legendOrder.filter(present.contains)
    }
}

private struct DiffLegend: View {
    let kinds: [TextComparison.Span.Kind]

    var body: some View {
        if !kinds.isEmpty {
            HStack(spacing: 12) {
                ForEach(kinds, id: \.self) { kind in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: DiffStyle.swatch(kind)))
                            .frame(width: 16, height: 11)
                        Text(DiffStyle.label(kind)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }
}

struct DiffTextPresentation {
    let attributed: NSAttributedString
    private let original: NSString
    private let displayRanges: [NSRange?]

    static func render(spans: [TextComparison.Span]) -> DiffTextPresentation {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

        guard !spans.isEmpty else {
            var placeholder = base
            placeholder[.foregroundColor] = NSColor.tertiaryLabelColor
            return DiffTextPresentation(
                attributed: NSAttributedString(string: "(empty)", attributes: placeholder),
                original: "",
                displayRanges: Array(repeating: nil, count: "(empty)".utf16.count))
        }

        let out = NSMutableAttributedString()
        var original = ""
        var displayRanges: [NSRange?] = []

        for span in spans {
            var attributes = base
            let color = DiffStyle.foreground(span.kind)
            attributes[.foregroundColor] = color
            if let background = DiffStyle.background(span.kind) {
                attributes[.backgroundColor] = background
            }
            switch DiffStyle.mark(span.kind) {
            case .none:
                break
            case .strikethrough:
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = color
            case .underline:
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = color
            }

            let reveal = span.kind != .unchanged
            for character in span.text {
                let originalRange = NSRange(location: original.utf16.count, length: String(character).utf16.count)
                original.append(character)
                let displayed = reveal ? visible(character) : String(character)
                out.append(NSAttributedString(string: displayed, attributes: attributes))
                for _ in 0..<displayed.utf16.count {
                    displayRanges.append(originalRange)
                }
            }
        }

        return DiffTextPresentation(attributed: out, original: original as NSString, displayRanges: displayRanges)
    }

    func originalText(for displayRange: NSRange) -> String {
        guard displayRange.length > 0 else { return "" }
        let start = max(0, displayRange.location)
        let end = min(displayRanges.count, displayRange.location + displayRange.length)
        guard start < end else { return "" }
        let ranges = displayRanges[start..<end].compactMap { $0 }
        guard var combined = ranges.first else { return "" }
        for range in ranges.dropFirst() {
            combined = NSUnionRange(combined, range)
        }
        return original.substring(with: combined)
    }

    private static func visible(_ character: Character) -> String {
        switch character {
        case "\n": return "\u{21B5}\n"
        case "\r": return "\u{240D}"
        case "\t": return "\u{21E5}"
        case " ": return "\u{00B7}"
        case "\u{00A0}": return "\u{237D}"
        default: return String(character)
        }
    }
}

private struct ComparisonPane: View {
    let title: String
    let role: ComparisonTextRole
    let spans: [TextComparison.Span]
    let onSelect: (ComparisonTextRole, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if role == .heard {
                    Label("Select to correct", systemImage: "cursorarrow.click")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            SelectableComparisonText(spans: spans) { onSelect(role, $0) }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if role == .heard {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                    }
                }
        }
    }
}

private struct SelectableComparisonText: NSViewRepresentable {
    let spans: [TextComparison.Span]
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Rebuild only when the spans actually change. Rebuilding on every render collapsed the user's
        // selection (the selection itself triggers a re-render), and restoring an old range into changed
        // text both selected the wrong characters and fired a stale onSelect. Keep the selection across a
        // pure attribute change (same text, different highlight); reset it on a real text change.
        guard context.coordinator.renderedSpans != spans else { return }
        let previousString = textView.string
        let rendered = DiffTextPresentation.render(spans: spans)
        let attributed = rendered.attributed
        let selected = textView.selectedRange()
        textView.textStorage?.setAttributedString(attributed)
        context.coordinator.renderedSpans = spans
        context.coordinator.presentation = rendered
        if previousString == attributed.string,
            selected.location + selected.length <= attributed.string.utf16.count {
            textView.setSelectedRange(selected)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String) -> Void
        var renderedSpans: [TextComparison.Span]?
        var presentation: DiffTextPresentation?
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onSelect(presentation?.originalText(for: textView.selectedRange()) ?? "")
        }
    }
}

private struct CreateReplacementSheet: View {
    let initialSource: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var replace = ""
    @FocusState private var focus: Field?

    private enum Field { case source, replace }

    init(initialSource: String, onSave: @escaping (String, String) -> Void) {
        self.initialSource = initialSource
        self.onSave = onSave
        _source = State(initialValue: initialSource)
    }

    private var sourceTrimmed: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var replaceTrimmed: String { replace.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNoop: Bool {
        !sourceTrimmed.isEmpty && sourceTrimmed.caseInsensitiveCompare(replaceTrimmed) == .orderedSame
    }
    private var canSave: Bool { !sourceTrimmed.isEmpty && !isNoop }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Replacement").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("When \(Branding.appName) hears").font(.caption).foregroundStyle(.secondary)
                TextField("The misheard words", text: $source)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .source).onSubmit { save() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Replace with").font(.caption).foregroundStyle(.secondary)
                TextField("What it should say", text: $replace)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .replace).onSubmit { save() }
            }
            if isNoop {
                Text("That is the same as what was heard, so it would do nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Applies to future dictations in every mode that uses replacements.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Replacement") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { focus = sourceTrimmed.isEmpty ? .source : .replace }
    }

    private func save() {
        guard canSave else { return }
        onSave(sourceTrimmed, replaceTrimmed)
        dismiss()
    }
}

private struct AddToDictionarySheet: View {
    let initialTerm: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @FocusState private var termFocused: Bool

    init(initialTerm: String, onSave: @escaping (String) -> Void) {
        self.initialTerm = initialTerm
        self.onSave = onSave
        _term = State(initialValue: initialTerm)
    }

    private var trimmed: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Dictionary").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Word or term").font(.caption).foregroundStyle(.secondary)
                TextField("A name, product term, or jargon", text: $term)
                    .textFieldStyle(.roundedBorder).focused($termFocused)
                    .onSubmit { save() }
            }
            Text("A best-effort recognition hint for future dictations; its strength varies by model. When a phrase is always misheard the same way, a replacement fixes it exactly.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Dictionary") { save() }
                    .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { termFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
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
