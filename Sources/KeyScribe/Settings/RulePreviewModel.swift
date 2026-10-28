import Foundation
import KeyScribeKit

// Live preview for a replacement rule being written: what it does to the user's recent dictations and to a
// sample sentence. History is read once per editor for the live preview; an explicit rule check reads it again.
@MainActor
final class RulePreviewModel: ObservableObject {
    struct Source {
        let scope: ReplacementPreview.Destination
        // Read off the main thread after the debounce: it loads config files.
        let config: @Sendable () -> RuleEffectPreview.Config
        // nil while History is off, so only the sample can be shown.
        let history: (@Sendable () throws -> [HistorySnapshot.Item])?

        static var unavailable: Source {
            Source(
                scope: .global,
                config: { .init(modes: [], dictionary: DictionarySet(), replacements: ReplacementsSet()) },
                history: nil)
        }
    }

    nonisolated static let historyLimit = 200

    @Published var sampleText = "" { didSet { if sampleText != oldValue { schedule() } } }
    @Published private(set) var history: RuleEffectPreview?
    @Published private(set) var sample: RuleEffectPreview.Entry?
    @Published private(set) var audit: RuleEffectPreview.Audit?
    @Published private(set) var isWorking = false
    @Published private(set) var historyFailed = false
    // An existing rule opened unchanged is shown against the scope without it; any edit is shown against
    // today's saved rules, so the preview says what saving would change.
    @Published private(set) var comparesEdit = false

    private let source: Source
    private let debounce: Duration
    private var draft: ReplacementsSet.Rule?
    private var original: ReplacementsSet.Rule?
    private var items: [HistorySnapshot.Item]?
    private(set) var work: Task<Void, Never>?

    var historyAvailable: Bool { source.history != nil }

    init(source: Source, debounce: Duration = .milliseconds(250)) {
        self.source = source
        self.debounce = debounce
    }

    func update(draft: ReplacementsSet.Rule?, original: ReplacementsSet.Rule?) {
        self.draft = draft
        self.original = original
        schedule()
    }

    func close() { work?.cancel() }

    func clearAudit() { audit = nil }

    func checkRules() async {
        guard let loadHistory = source.history else { return }
        work?.cancel()
        isWorking = true
        let scope = source.scope, config = source.config
        let result = try? await Self.offMain { () -> ([HistorySnapshot.Item]?, RuleEffectPreview.Audit?) in
            guard let loaded = try? loadHistory() else { return (nil, nil) }
            return (loaded, try RuleEffectPreview.audit(
                scope: scope, config: config(), history: loaded, limit: Self.historyLimit))
        }
        guard !Task.isCancelled else { return }
        if let loaded = result?.0 { items = loaded }
        historyFailed = result?.0 == nil
        audit = result?.1
        isWorking = false
    }

    private func schedule() {
        work?.cancel()
        isWorking = true
        let draft = draft, original = original, sampleText = sampleText
        let baseline: RuleEffectPreview.Baseline = original != nil && draft == original ? .withoutRule : .current
        let scope = source.scope, config = source.config, loadHistory = source.history
        let cached = items, debounce = debounce
        work = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let computed = try? await Self.offMain { () -> Computed in
                let config = config()
                var loaded = cached
                var failed = false
                if loaded == nil, let loadHistory {
                    do { loaded = try loadHistory() } catch { failed = true }
                }
                let history = try loaded.map {
                    try RuleEffectPreview.make(
                        draft: draft, replacing: original, scope: scope, config: config,
                        history: $0, limit: Self.historyLimit, baseline: baseline)
                }
                let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
                let sample = trimmed.isEmpty ? nil : try? RuleEffectPreview.sample(
                    sampleText, draft: draft, replacing: original, scope: scope, config: config, baseline: baseline)
                return Computed(items: loaded, history: history, sample: sample, failed: failed)
            }
            guard let self, let computed, !Task.isCancelled else { return }
            self.items = computed.items
            self.history = computed.history
            self.sample = computed.sample
            self.historyFailed = computed.failed
            self.comparesEdit = baseline == .current && original != nil
            self.isWorking = false
        }
    }

    // Detached so the replay never runs on the main actor, and cancelled with the task that awaits it.
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private struct Computed: Sendable {
        let items: [HistorySnapshot.Item]?
        let history: RuleEffectPreview?
        let sample: RuleEffectPreview.Entry?
        let failed: Bool
    }
}
