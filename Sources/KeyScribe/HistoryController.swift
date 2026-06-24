import AppKit
import KeyScribeKit
import SwiftUI

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
        openSettings: @escaping () -> Void
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
        window.setContentSize(NSSize(width: 860, height: 560))
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
    let openSettings: () -> Void
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
        openSettings: @escaping () -> Void
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
        recomputeGroups()
        isLoading = false
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
                        Button("Open History Settings") { model.openSettings() }
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
            .safeAreaInset(edge: .bottom) { storageTruth }
        } detail: {
            if let entry = model.selected {
                HistoryDetailView(entry: entry, model: model)
            } else {
                ContentUnavailableView(
                    "No dictation selected", systemImage: "clock",
                    description: Text("Select an entry to see Heard → Transformed → Result and correction actions."))
            }
        }
    }

    private var storageTruth: some View {
        Text("History stays on this Mac. Audio is never saved. Stored transcripts and final text can still contain sensitive information.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
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
    case heard = "Heard"
    case transformed = "Transformed"
    case details = "Details"
    var id: String { rawValue }
}

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryViewModel
    @State private var stage: DetailStage = .result
    @State private var selectedText = ""
    @State private var showReplacementSheet = false
    @State private var showDictionarySheet = false

    // Transformed is a distinct stage only when local edits actually changed the transcript; otherwise
    // Heard already equals Result and the segment would be noise (ui_design.md §8).
    private var hasTransformed: Bool {
        if let t = entry.transformed { return t != entry.result }
        return false
    }

    private var stages: [DetailStage] {
        DetailStage.allCases.filter { $0 != .transformed || hasTransformed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionBar
            Picker("", selection: $stage) {
                ForEach(stages) { Text($0.rawValue).tag($0) }
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
            if !stages.contains(stage) { stage = .result }
        }
        .onChange(of: stage) { selectedText = "" }
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
        case .result: selectable(entry.result)
        case .heard: selectable(entry.heard)
        case .transformed: selectable(entry.transformed ?? entry.result)
        case .details: details
        }
    }

    private func selectable(_ value: String) -> some View {
        SelectableText(text: value) { selectedText = $0 }
            .frame(minHeight: 80, maxHeight: 280)
    }

    // The replacement trigger is the misheard fragment, so it comes from the selection (or stays empty
    // for a deliberate shortcut). It is never prefilled from the whole result: a global rule built from a
    // paragraph would mangle every dictation containing it.
    private var replacementSource: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A dictionary term is a single word. Prefer the selection; otherwise offer a one-word result.
    private var dictionarySource: String {
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        let result = entry.result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.contains(where: \.isWhitespace) ? "" : result
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
            Text("Corrections").font(.headline)
            HStack {
                Button("Create Replacement…") { showReplacementSheet = true }
                Button("Add to Dictionary…") { showDictionarySheet = true }
            }
            Text(correctionHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var correctionHint: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Select the misheard words above first, so the correction targets just that phrase."
            : "Using your selection \u{201C}\(replacementSource)\u{201D}."
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Privacy & processing").font(.headline)
                detailRow("AI rewrite", rewriteSummary)
                detailRow("Best-effort redaction", entry.redaction ? "Applied" : "Not applied")
                detailRow("Speech", "On-device")
                detailRow("Context sent", entry.contextLabels.isEmpty ? "None" : entry.contextLabels.joined(separator: ", "))
            }
            if let prompt = entry.prompt {
                DisclosureGroup("Show exactly what was sent") {
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

// A read-only, selectable text area that reports the user's current selection. SwiftUI's
// `.textSelection` cannot hand back the selected range, and the correction flow needs the exact
// misheard fragment, so the Heard/Result stages use this AppKit-backed view instead.
private struct SelectableText: NSViewRepresentable {
    let text: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.string = text.isEmpty ? "(empty)" : text
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
        let display = text.isEmpty ? "(empty)" : text
        if textView.string != display {
            textView.string = display
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onSelect((textView.string as NSString).substring(with: textView.selectedRange()))
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
                Text("When KeyScribe hears").font(.caption).foregroundStyle(.secondary)
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
