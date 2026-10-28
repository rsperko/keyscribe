import AppKit
import KeyScribeKit
import SwiftUI

// The standalone correction surfaces (design.md §4.7): a panel to add a dictionary term or replacement without
// opening Settings. The Heard/term field is pre-filled best-effort from the current selection, captured before
// KeyScribe activates so the synthetic ⌘C still reaches the app the user was working in. The prefill is a
// convenience only: it reads the selection via Accessibility, and where a ⌘C would be needed (AX-unavailable) only
// when the clipboard restores perfectly — it never risks a rich/image clipboard to prefill a word the user can type.
//
// "Add & Correct" saves the entry, then pastes the corrected value back over that selection via the shared safe
// insertion path (single ⌘Z) — only once the stashed source app is confirmed frontmost, never blind. If focus
// cannot be handed back, the entry is still saved and the panel says the text was left unchanged.
@MainActor
final class CorrectionPanelController {
    private var window: NSWindow?
    private let destinations: () -> [CorrectionDestination]
    private let analyze: (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis
    private let addDictionaryWord: (String, CorrectionDestination) -> ConfigRepository.AddResult
    private let addReplacement: (String, String, Bool, Bool?, CorrectionDestination) -> ConfigRepository.AddResult
    private let existingRule: (String, Bool, CorrectionDestination) -> ReplacementsSet.Rule?
    private let captureSelection: () async -> String?
    // Set once Settings exists: the History finder for a word in a destination. nil means no History to search.
    var mishearingsFinder: ((String, CorrectionDestination, @escaping (Int) -> Void) -> HistoryReplacementsModel?)?
    private let clipboardPaste: () -> ClipboardPaste
    private var previousApp: NSRunningApplication?
    private let status = CorrectionPanelStatus()

    init(
        destinations: @escaping () -> [CorrectionDestination] = { [.global] },
        analyze: @escaping (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis,
        addDictionaryWord: @escaping (String, CorrectionDestination) -> ConfigRepository.AddResult,
        addReplacement: @escaping (String, String, Bool, Bool?, CorrectionDestination) -> ConfigRepository.AddResult,
        existingRule: @escaping (String, Bool, CorrectionDestination) -> ReplacementsSet.Rule? = { _, _, _ in nil },
        captureSelection: @escaping () async -> String? = { await TextInserter.captureSelection(requirePerfectRestore: true) },
        clipboardPaste: @escaping () -> ClipboardPaste = { ClipboardPaste() }
    ) {
        self.destinations = destinations
        self.analyze = analyze
        self.addDictionaryWord = addDictionaryWord
        self.addReplacement = addReplacement
        self.existingRule = existingRule
        self.captureSelection = captureSelection
        self.clipboardPaste = clipboardPaste
    }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let selection = (await captureSelection())?.trimmingCharacters(in: .whitespacesAndNewlines)
            show(prefill: selection?.isEmpty == false ? selection : nil)
        }
    }

    private var hasPasteTarget: Bool {
        guard let app = previousApp else { return false }
        return app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func show(prefill: String?) {
        window?.close()
        status.message = nil
        status.addedWord = nil
        status.mishearings = nil
        let view = CorrectionPanelView(
            prefill: prefill ?? "",
            canCorrect: prefill != nil && hasPasteTarget,
            destinations: destinations(),
            analyze: analyze,
            existingRule: existingRule,
            status: status,
            onSave: { [weak self] result in
                guard let self else { return }
                switch self.apply(result) {
                case .saved:
                    if case .dictionary(let word, let destination) = result {
                        self.offerMishearings(of: word, in: destination, afterAdding: true)
                    } else {
                        self.window?.close()
                    }
                case .noChange:
                    self.status.refresh()
                case .failed(let refusal):
                    self.status.message = refusal ?? Self.saveFailedMessage(for: Self.destination(of: result))
                }
            },
            onCorrect: { [weak self] result, pasteText in self?.applyAndCorrect(result, pasteText: pasteText) },
            onReview: { [weak self] word, destination in self?.offerMishearings(of: word, in: destination, afterAdding: false) },
            onCancel: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Add to Vocabulary"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    var canReviewMishearings: Bool { mishearingsFinder != nil }

    // After a word is added the review opens only when History holds likely mishearings; otherwise the panel
    // says how to teach a spelling later. Asked for explicitly, the review always opens.
    private func offerMishearings(of word: String, in destination: CorrectionDestination, afterAdding: Bool) {
        let finder = mishearingsFinder?(word, destination) { [weak self] count in
            self?.status.mishearings = nil
            self?.status.message = nil
            if afterAdding { self?.window?.close() } else {
                self?.status.notice = count == 1 ? "Added 1 replacement." : "Added \(count) replacements."
            }
        }
        guard let finder else {
            if afterAdding { status.addedWord = word }
            return
        }
        finder.offeredAfterAdding = afterAdding
        Task { @MainActor [weak self] in
            if afterAdding {
                guard let shown = await Self.reviewWorthShowing(finder) else {
                    self?.status.addedWord = word
                    return
                }
                self?.status.mishearings = shown
            } else {
                self?.status.mishearings = finder
            }
        }
    }

    static func reviewWorthShowing(_ finder: HistoryReplacementsModel) async -> HistoryReplacementsModel? {
        await finder.refresh()
        guard !finder.findings.isEmpty else { finder.close(); return nil }
        return finder
    }

    func dismissMishearings() {
        let afterAdding = status.mishearings?.offeredAfterAdding == true
        status.mishearings?.close()
        status.mishearings = nil
        if afterAdding { window?.close() }
    }

    private enum SaveOutcome { case saved, noChange, failed(refusal: String?) }

    private func apply(_ result: CorrectionPanelView.SaveResult) -> SaveOutcome {
        if case .noChange = analyze(Self.proposal(of: result), Self.destination(of: result)).action {
            return .noChange
        }
        let added: ConfigRepository.AddResult
        switch result {
        case .dictionary(let word, let destination): added = addDictionaryWord(word, destination)
        case .replacement(let heard, let replace, let regex, let wholeDictation, let destination):
            added = addReplacement(heard, replace, regex, wholeDictation, destination)
        }
        switch added {
        case .saved: return .saved
        case .refused(let message): return .failed(refusal: message)
        case .failed: return .failed(refusal: nil)
        }
    }

    static func saveFailedMessage(for destination: CorrectionDestination) -> String {
        switch destination.scope {
        case .global:
            return "\(Branding.appName) could not save this — a configuration file may be malformed. Open Settings ▸ Maintenance to fix it."
        case .mode:
            return "\(Branding.appName) could not save this to \(destination.title). Its mode file may be malformed. Open Settings ▸ Modes to fix it."
        }
    }

    private static func destination(of result: CorrectionPanelView.SaveResult) -> CorrectionDestination {
        switch result {
        case .dictionary(_, let d): return d
        case .replacement(_, _, _, _, let d): return d
        }
    }

    private static func proposal(of result: CorrectionPanelView.SaveResult) -> VocabularyProposal {
        switch result {
        case .dictionary(let word, _): return .word(word)
        case .replacement(let heard, let replace, let regex, _, _):
            return .replacement(heard: heard, replace: replace, regex: regex)
        }
    }

    private func applyAndCorrect(_ result: CorrectionPanelView.SaveResult, pasteText: String) {
        switch apply(result) {
        case .failed(let refusal):
            status.message = refusal ?? Self.saveFailedMessage(for: Self.destination(of: result))
            return
        case .noChange, .saved:
            break
        }
        status.message = nil
        guard hasPasteTarget, let target = previousApp, !pasteText.isEmpty else {
            window?.close()
            return
        }
        window?.orderOut(nil)
        Task { @MainActor in
            guard await TextInserter.pasteReturning(to: target, text: pasteText, paste: clipboardPaste()) else {
                status.message = "Saved to your vocabulary. \(Branding.appName) could not return to the app, so the selected text was not changed."
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                return
            }
            window?.close()
        }
    }
}

@MainActor
final class CorrectionPanelStatus: ObservableObject {
    @Published var message: String?
    @Published var notice: String?
    @Published var addedWord: String?
    @Published var mishearings: HistoryReplacementsModel?
    @Published private(set) var revision = 0

    func refresh() { revision += 1 }
}

struct CorrectionDestination: Hashable, Identifiable {
    enum Scope: Hashable {
        case global
        case mode(String)
    }

    let scope: Scope
    let title: String
    let menuTitle: String

    var id: Scope { scope }

    static let global = CorrectionDestination(scope: .global, title: "Global", menuTitle: "Global")

    static func mode(id: String, name: String) -> CorrectionDestination {
        CorrectionDestination(scope: .mode(id), title: name, menuTitle: name)
    }

    var scopeLine: String {
        switch scope {
        case .global: "Saved on this Mac. Applies in modes that include Global vocabulary."
        case .mode: "Saved on this Mac. Applies only in \(title)."
        }
    }

    // Global plus the user's enabled, non-system modes. A disabled mode is excluded: a term routed there
    // would do nothing until the mode is enabled, with no hint at the panel.
    static func list(for modes: [Mode]) -> [CorrectionDestination] {
        [.global] + modes.filter { $0.hasOwnVocabulary && $0.enabled }.map { .mode(id: $0.id, name: $0.name) }
    }
}

private struct CorrectionPanelView: View {
    enum SaveResult {
        case dictionary(word: String, destination: CorrectionDestination)
        case replacement(heard: String, replace: String, regex: Bool, wholeDictation: Bool?, destination: CorrectionDestination)
    }

    // The selection captured when the panel opened. "Add & Replace Selection" pastes the rule's effect
    // on *this* text, so a regex is applied to the original selection — not to the pattern field.
    let originalSelection: String
    let canCorrect: Bool
    let destinations: [CorrectionDestination]
    let analyze: (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis
    let existingRule: (String, Bool, CorrectionDestination) -> ReplacementsSet.Rule?
    let onSave: (SaveResult) -> Void
    let onCorrect: (SaveResult, String) -> Void
    let onReview: (String, CorrectionDestination) -> Void
    let onCancel: () -> Void
    @ObservedObject var status: CorrectionPanelStatus

    @State private var term: String
    @State private var replace: String
    @State private var regex = false
    @State private var chosenWholeDictation: Bool?
    @State private var advancedExpanded = false
    @State private var destination: CorrectionDestination
    @FocusState private var focus: Field?

    private enum Field { case term, replace }

    init(
        prefill: String, canCorrect: Bool,
        destinations: [CorrectionDestination],
        analyze: @escaping (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis,
        existingRule: @escaping (String, Bool, CorrectionDestination) -> ReplacementsSet.Rule?,
        status: CorrectionPanelStatus,
        onSave: @escaping (SaveResult) -> Void, onCorrect: @escaping (SaveResult, String) -> Void,
        onReview: @escaping (String, CorrectionDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let destinations = destinations.isEmpty ? [.global] : destinations
        self.originalSelection = prefill
        self.canCorrect = canCorrect
        self.destinations = destinations
        self.analyze = analyze
        self.existingRule = existingRule
        self.status = status
        self.onSave = onSave
        self.onCorrect = onCorrect
        self.onReview = onReview
        self.onCancel = onCancel
        _term = State(initialValue: prefill)
        _replace = State(initialValue: "")
        _destination = State(initialValue: destinations[0])
    }

    var body: some View {
        Group {
            if let added = status.addedWord {
                addedConfirmation(added)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheet(item: Binding(get: { status.mishearings }, set: { if $0 == nil { status.mishearings = nil } })) { finder in
            HistoryReplacementsSheet(model: finder) { onCancelReview(finder) }
        }
    }

    private func onCancelReview(_ finder: HistoryReplacementsModel) {
        finder.close()
        status.mishearings = nil
        if finder.offeredAfterAdding { onCancel() }
    }

    private func addedConfirmation(_ word: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(word)” added").font(.headline)
            Text("No other spellings found in saved History yet. When “\(word)” is misheard, select the wrong words and open Add to Vocabulary again to correct them.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(destination.scopeLine).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.Correction.done)
            }
        }
    }

    private var form: some View {
        let draft = draft
        let rule = draftRule(draft)
        let teach = regex ? nil : VocabularyDraftAnalysis.teachableCorrection(
            selected: originalSelection, term: trimmedTerm, action: draft.analysis?.action)
        let alreadyAdded = !regex && replace.isEmpty && VocabularyDraftAnalysis.isAlreadyAdded(draft.analysis?.action)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(regex ? "Heard pattern" : "Word or heard phrase")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(regex ? "Regular expression" : "e.g. Kubernetes", text: $term)
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .term)
                    .onSubmit(commitSave)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(AccessibilityID.Correction.term)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(regex ? "Use instead" : "Use instead (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReplacementValueField(
                    title: regex ? "Use instead" : "Use instead (optional)",
                    placeholder: regex ? "Replacement text" : "Optional correction",
                    text: $replace,
                    fieldID: AccessibilityID.Correction.useInstead,
                    onSubmit: commitSave)
                if !regex {
                    Text("Leave Use instead empty to add a word.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let feedback = draft.feedback {
                VocabularyFeedbackView(feedback: feedback)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Correction.status)
            }
            if alreadyAdded {
                HStack(spacing: 12) {
                    if let teach {
                        Button("Correct “\(teach.heard)” to “\(teach.word)”") {
                            onSave(.replacement(heard: teach.heard, replace: teach.word, regex: false, wholeDictation: nil, destination: destination))
                        }
                        .accessibilityIdentifier(AccessibilityID.Correction.teach)
                    }
                    Button("Review Mishearings…") { onReview(trimmedTerm, destination) }
                        .accessibilityIdentifier(AccessibilityID.Correction.review)
                }
                .controlSize(.small)
            }
            if let summary = draft.replacementSummary(in: destination) {
                Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let rule {
                if let behavior = ReplacementAuthoring.behaviorSummary(
                    replace: rule.replace, regex: rule.regex, wholeDictation: rule.wholeDictation) {
                    Text(behavior).font(.callout)
                }
                if let advisory = ReplacementAuthoring.returnScopeAdvisory(
                    replace: rule.replace, regex: rule.regex, wholeDictation: rule.wholeDictation) {
                    IssueText(advisory, severity: .advisory)
                    Button("Only Match When Said Alone") { chosenWholeDictation = true }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Text("Save to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if destinations.count == 1 {
                    Text(destination.title)
                        .font(.callout)
                        .foregroundStyle(.primary)
                } else {
                    Picker("", selection: $destination) {
                        ForEach(destinations) { destination in
                            Text(destination.menuTitle).tag(destination)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityID.Correction.destination)
                }
                Spacer()
            }
            Text(destination.scopeLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureSection("Advanced", isExpanded: Binding(get: { advancedExpanded || regex }, set: { advancedExpanded = $0 })) {
                Toggle("Match heard phrase as a regular expression", isOn: $regex)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(AccessibilityID.Correction.regexToggle)
                if regex {
                    Text("Use captures like $1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if rule != nil {
                    RuleScopePicker(wholeDictation: wholeDictation, id: AccessibilityID.Correction.scope)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Correction.advanced)

            if let issue = draft.validationIssue {
                VocabularyDraftIssueText(issue: issue)
            }
            if let message = status.message {
                IssueText(message, severity: .advisory)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = status.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.Correction.cancel)
                if canCorrect && hasReplacementValue {
                    Button("Add & Replace Selection") { onCorrect(buildResult(), correctionPasteText()) }
                        .disabled(!(draft.canApplyCorrection && hasReplacementValue && !correctedValue.isEmpty))
                        .accessibilityIdentifier(AccessibilityID.Correction.addAndReplace)
                }
                Button(draft.buttonTitle, action: commitSave)
                    .keyboardShortcut(.defaultAction).disabled(!draft.canCommit)
                    .accessibilityIdentifier(AccessibilityID.Correction.add)
            }
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                focus = .term
            }
        }
    }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var correctedValue: String {
        replace.isEmpty ? trimmedTerm : replace
    }

    private var hasReplacementValue: Bool { !replace.isEmpty }

    private var draft: VocabularyDraftAnalysis {
        _ = status.revision
        return VocabularyDraftAnalysis(
            term: trimmedTerm, replacement: replace, regex: regex,
            analyze: { analyze($0, destination) })
    }

    // The same default as the Settings composer: a new Return-pressing rule matches only when said alone, an
    // update keeps the saved rule's choice, until the user picks under Advanced.
    private var wholeDictation: Binding<Bool> {
        Binding(
            get: {
                chosenWholeDictation ?? existingRule(trimmedTerm, regex, destination)?.wholeDictation
                    ?? ReplacementAuthoring.pressesReturn(replace: replace, regex: regex)
            },
            set: { chosenWholeDictation = $0 })
    }

    private func draftRule(_ draft: VocabularyDraftAnalysis) -> ReplacementsSet.Rule? {
        guard case let .replacement(heard, replace, regex)? = draft.proposal else { return nil }
        return ReplacementsSet.Rule(heard: heard, replace: replace, regex: regex, wholeDictation: wholeDictation.wrappedValue)
    }

    // What "Add & Replace Selection" pastes over the captured selection: the replacement text, or — for a
    // regex rule — the rule applied to the original selection (not to the pattern in the heard field).
    private func correctionPasteText() -> String {
        guard regex else { return correctedValue }
        return CorrectionReplacement.apply(
            to: originalSelection,
            pattern: trimmedTerm,
            replacement: replace)
    }

    private func commitSave() {
        guard draft.canCommit else { return }
        onSave(buildResult())
    }

    private func buildResult() -> SaveResult {
        if !regex && replace.isEmpty {
            return .dictionary(word: trimmedTerm, destination: destination)
        }
        return .replacement(
            heard: trimmedTerm, replace: replace, regex: regex, wholeDictation: wholeDictation.wrappedValue,
            destination: destination)
    }
}

enum CorrectionReplacement {
    static func apply(to text: String, pattern: String, replacement: String) -> String {
        guard ReplacementSafety.isSafe(pattern),
              let regex = RegexCache.regex(pattern, options: [.caseInsensitive]),
              let parsed = ReturnSuffix.parse(ReplacementEscapes.expandTemplate(replacement))
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: parsed.template)
    }

}
