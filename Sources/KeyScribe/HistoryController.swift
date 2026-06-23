import AppKit
import KeyScribeKit
import SwiftUI

@MainActor
final class HistoryController {
    private var window: NSWindow?
    private let model: HistoryViewModel
    private var loadedSignature: String?

    init(
        store: HistoryStore,
        addDictionaryWord: @escaping (String) -> Void,
        addReplacement: @escaping (String, String) -> Void,
        openSettings: @escaping () -> Void
    ) {
        model = HistoryViewModel(
            store: store, addDictionaryWord: addDictionaryWord,
            addReplacement: addReplacement, openSettings: openSettings)
    }

    func present() {
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
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
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

    private static let loadLimit = 1000
    private var rows: [HistoryRow] = []
    private var entryIndex: [HistoryRow.ID: HistoryEntry] = [:]
    private var recomputeTask: Task<Void, Never>?

    private let store: HistoryStore
    let addDictionaryWord: (String) -> Void
    let addReplacement: (String, String) -> Void
    let openSettings: () -> Void

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
        Task { @MainActor [weak self] in
            let loaded = await Task.detached { store.entries(limit: limit) }.value
            guard let self else { return }
            rows = loaded.map { HistoryRow(entry: $0, day: dayFormatter.string(from: $0.timestamp)) }
            entryIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.entry) })
            recomputeGroups()
            isLoading = false
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
    }

    var selected: HistoryEntry? { selection.flatMap { entryIndex[$0] } }
    var hasEntries: Bool { !rows.isEmpty }
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

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryViewModel
    @State private var dictionaryTerm = ""
    @State private var heard = ""
    @State private var replace = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                labeled("Heard", entry.heard)
                if let transformed = entry.transformed, transformed != entry.result {
                    labeled("Transformed", transformed)
                }
                labeled("Result", entry.result)
                corrections
                processingDetails
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncFields() }
        .onChange(of: entry.timestamp) { syncFields() }
    }

    private func syncFields() {
        let trimmedResult = entry.result.trimmingCharacters(in: .whitespacesAndNewlines)
        dictionaryTerm = trimmedResult.contains(where: \.isWhitespace) ? "" : trimmedResult
        heard = entry.heard
        replace = entry.result
    }

    private var heardPreview: String {
        let t = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "the heard text" : t
    }

    private var replacePreview: String {
        let t = replace.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(nothing)" : t
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

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "(empty)" : value).textSelection(.enabled)
        }
    }

    private var corrections: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Corrections").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Add a term to the dictionary", text: $dictionaryTerm)
                    Button("Add to Dictionary") {
                        model.addDictionaryWord(dictionaryTerm)
                        dictionaryTerm = ""
                    }
                    .disabled(dictionaryTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Adds to your global dictionary — a recognition hint for every mode that uses it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Heard", text: $heard)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Replace with", text: $replace)
                    Button("Create Replacement") { model.addReplacement(heard, replace) }
                        .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Adds a global replacement — every mode that uses replacements turns \u{201C}\(heardPreview)\u{201D} into \u{201C}\(replacePreview)\u{201D}.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var processingDetails: some View {
        DisclosureGroup("Processing details") {
            VStack(alignment: .leading, spacing: 8) {
                if let connection = entry.connection {
                    detailRow("Connection", connection + (entry.model.map { " · \($0)" } ?? ""))
                }
                detailRow("Best-effort redaction", entry.redaction ? "On" : "Off")
                detailRow("Context sent", entry.contextLabels.isEmpty ? "None" : entry.contextLabels.joined(separator: ", "))
                if let prompt = entry.prompt {
                    Text("Prompt sent").font(.caption).foregroundStyle(.secondary)
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Redaction maps are never shown or stored.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
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
