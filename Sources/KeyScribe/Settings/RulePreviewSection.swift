import SwiftUI
import KeyScribeKit

// The rule editor's "what will this do" block, in reading order: one sentence when the rule is not an
// ordinary word fix, warnings with their repair, a sample sentence, and the rule replayed over recent
// History behind one summary line. Warnings are advisories, not errors — a substring rule can be intended.
struct RulePreviewSection: View {
    @ObservedObject var model: RulePreviewModel
    let draft: ReplacementsSet.Rule
    let ids: AccessibilityID.Settings.RulePreviewIDs
    let onUsePattern: (String) -> Void
    var onMatchAlone: (() -> Void)? = nil
    @State private var offeringWholeWords = false
    @State private var showingAll = false
    @State private var historyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = ReplacementAuthoring.behaviorSummary(
                replace: draft.replace, regex: draft.regex, wholeDictation: draft.wholeDictation) {
                Text(summary).font(.callout)
            }
            if let advisory = ReplacementAuthoring.returnScopeAdvisory(
                replace: draft.replace, regex: draft.regex, wholeDictation: draft.wholeDictation) {
                IssueText(advisory, severity: .advisory)
                if let onMatchAlone {
                    Button("Only Match When Said Alone", action: onMatchAlone)
                        .controlSize(.small)
                        .accessibilityIdentifier(ids.matchAlone)
                }
            }
            if let example = insideWordExample {
                IssueText("Also changes text inside other words, like “\(example.before)” → “\(example.after)”.",
                          severity: .advisory)
                wholeWordsFix
            }
            sampleBlock
            historyBlock
        }
        .onChange(of: draft) {
            offeringWholeWords = false
            showingAll = false
        }
    }

    @ViewBuilder private var wholeWordsFix: some View {
        if draft.regex, let wrapped = ReplacementAuthoring.wholeWordPattern(draft.heard) {
            if offeringWholeWords {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The pattern becomes:").font(.caption).foregroundStyle(.secondary)
                    Text(wrapped).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Use This Pattern") { onUsePattern(wrapped) }
                            .accessibilityIdentifier(ids.usePattern)
                        Button("Cancel") { offeringWholeWords = false }
                    }
                    .controlSize(.small)
                }
            } else {
                Button("Match Whole Words…") { offeringWholeWords = true }
                    .controlSize(.small)
                    .accessibilityIdentifier(ids.wholeWords)
            }
        }
    }

    private var sampleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Try a sentence", text: $model.sampleText, prompt: Text("Try a sentence"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(ids.sample)
            if let sample = model.sample {
                outcomeLine(sample.after)
            }
        }
    }

    @ViewBuilder private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.historyAvailable {
                caption("History is off, so there are no past dictations to check this against.")
            } else if model.historyFailed {
                IssueText("Your History could not be read, so this rule was not checked against it.", severity: .advisory)
            } else if let history = model.history {
                if history.checked == 0 {
                    caption("No recent dictations here to check this against yet.")
                } else if history.entries.isEmpty {
                    caption(summary(history))
                } else {
                    DisclosureSection(isExpanded: $historyExpanded) {
                        Text(summary(history))
                    } content: {
                        let shown = showingAll ? history.entries : Array(history.entries.prefix(Self.shownEntries))
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                            RuleEffectEntryView(entry: entry)
                        }
                        if history.entries.count > Self.shownEntries {
                            Button(showingAll ? "Show Fewer" : "Show All \(history.entries.count) Changes") { showingAll.toggle() }
                                .controlSize(.small)
                                .accessibilityIdentifier(ids.showAll)
                        }
                        caption("Local processing with today's settings. An AI rewrite can still change the result.")
                    }
                }
            } else if model.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ids.history)
    }

    static let shownEntries = 4

    private var insideWordExample: (before: String, after: String)? {
        let entries = (model.sample.map { [$0] } ?? []) + (model.history?.entries ?? [])
        guard let entry = entries.first(where: { $0.rule?.insideWord == true }) else { return nil }
        guard let change = entry.changes.first else { return nil }
        return (change.before, change.after)
    }

    private func summary(_ history: RuleEffectPreview) -> String {
        let n = history.entries.count
        let lead = model.comparesEdit ? "Saving this changes" : "Changes"
        guard n > 0 else { return "\(lead) none of \(history.checked) recent dictations" }
        return "\(lead) \(n) of \(history.checked) recent dictations"
    }

    private func outcomeLine(_ outcome: RuleEffectPreview.Outcome) -> some View {
        let tags = [outcome.skipsRewrite ? "skips the AI rewrite" : nil, outcome.submit != nil ? "presses Return" : nil]
            .compactMap { $0 }
        return Text("→ \(RuleEffectEntryView.visible(outcome.text))" + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// Where a rule acts. An unusual override, so it lives under Advanced: the default is right for almost every
// rule — a word fix acts in sentences, a new rule that presses Return matches only when said alone.
struct RuleScopePicker: View {
    @Binding var wholeDictation: Bool
    let id: String

    var body: some View {
        Picker("Acts", selection: $wholeDictation) {
            Text("Anywhere in a sentence").tag(false)
            Text("Only when said alone").tag(true)
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier(id)
    }
}
