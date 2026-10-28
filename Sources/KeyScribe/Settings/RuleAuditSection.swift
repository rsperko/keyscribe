import SwiftUI
import KeyScribeKit

// Replays every rule in the scope over recent dictations with today's rules, so a rule edited by hand — or
// one that never fired since it was fixed — is still checked. History is read again on every check.
struct RuleAuditSection: View {
    let rules: [ReplacementsSet.Rule]
    let onEdit: (ReplacementsSet.Rule) -> Void
    @StateObject private var model: RulePreviewModel

    init(source: RulePreviewModel.Source, rules: [ReplacementsSet.Rule], onEdit: @escaping (ReplacementsSet.Rule) -> Void) {
        self.rules = rules
        self.onEdit = onEdit
        _model = StateObject(wrappedValue: RulePreviewModel(source: source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Check Rules Against History") { Task { await model.checkRules() } }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.checkRules)
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            if model.historyFailed {
                IssueText("Your History could not be read, so the rules were not checked.", severity: .advisory)
            } else if let audit = model.audit {
                if audit.checked == 0 {
                    caption("Nothing to check: there are no past dictations here yet.")
                } else {
                    caption("Checked your last \(dictations(audit.checked)) here with today's rules. This is what they would do now, not a record of what happened.")
                    if audit.findings.isEmpty {
                        caption("No rule here changes text inside other words or drops its Return in them.")
                    }
                    ForEach(Array(audit.findings.enumerated()), id: \.offset) { _, finding in
                        findingRow(finding)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.checkRulesResults)
        .onChange(of: rules) { model.clearAudit() }
    }

    private func findingRow(_ finding: RuleEffectPreview.Finding) -> some View {
        let problems = [
            finding.insideWord > 0 ? "changes text inside other words in \(dictations(finding.insideWord))" : nil,
            finding.returnOmitted > 0 ? "would not press Return in \(dictations(finding.returnOmitted))" : nil,
        ].compactMap { $0 }.joined(separator: "; ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(finding.rule.heard).font(finding.rule.regex ? .caption.monospaced() : .caption)
                Spacer()
                Button("Edit Rule") { onEdit(finding.rule) }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.checkRulesEdit)
            }
            IssueText(problems.prefix(1).uppercased() + problems.dropFirst(), severity: .advisory)
            if let example = finding.example {
                RuleEffectEntryView(entry: example)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func dictations(_ n: Int) -> String { n == 1 ? "1 dictation" : "\(n) dictations" }
}

// One dictation a rule touches: where and when it was said, each changed span, what the rule did beyond the
// words, and the whole before/after on request — a change late in a long dictation is never cut off.
struct RuleEffectEntryView: View {
    let entry: RuleEffectPreview.Entry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let origin {
                Text(origin).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                Text("“\(Self.visible(change.before))” → “\(Self.visible(change.after))”").font(.caption)
            }
            ForEach(behaviour, id: \.self) { line in
                Text(line).font(.caption)
            }
            DisclosureSection("Show dictation", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Before: \(Self.visible(entry.before.text))").font(.caption).textSelection(.enabled)
                    Text("After: \(Self.visible(entry.after.text))").font(.caption).textSelection(.enabled)
                }
            }
            .font(.caption)
        }
        .padding(.leading, 8)
    }

    private var origin: String? {
        let parts = [entry.modeName, entry.date.map { $0.formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var behaviour: [String] {
        var lines: [String] = []
        if entry.before.submit != entry.after.submit {
            lines.append(entry.after.submit != nil ? "Now presses Return" : "No longer presses Return")
        }
        if entry.before.skipsRewrite != entry.after.skipsRewrite {
            lines.append(entry.after.skipsRewrite ? "Now skips the AI rewrite" : "No longer skips the AI rewrite")
        }
        if entry.rule?.returnOmitted == true, entry.after.submit == nil {
            lines.append("Matched mid-sentence, so its Return is not pressed")
        }
        return lines
    }

    static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }
}
