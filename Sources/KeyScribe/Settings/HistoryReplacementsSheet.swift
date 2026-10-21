import SwiftUI
import KeyScribeKit

struct HistoryReplacementsSheet: View {
    @ObservedObject var model: HistoryReplacementsModel
    let onCancel: () -> Void
    @State private var searchExpanded = false

    private typealias IDs = AccessibilityID.Settings.HistoryReplacements

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Form { content }
                .formStyle(.grouped)
            if let issue = model.issue {
                IssueText(issue)
                    .accessibilityIdentifier(IDs.issue)
            }
            Divider()
            buttons
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IDs.sheet)
        .task { if model.snapshot == nil, !model.loadFailed { await model.load() } }
    }

    @ViewBuilder private var header: some View {
        switch model.step {
        case .find:
            title("Find mishearings of “\(model.word)”",
                  "Look for similar phrases in Heard text, then choose replacements.")
        case .choose:
            title("Choose phrases for \(model.word)",
                  "These phrases resemble your word. Review what you meant in each sentence.")
        case .review:
            title("Review changes", "See what these replacements would change before you add them.")
        }
    }

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .find: findContent
        case .choose: chooseContent
        case .review: reviewContent
        }
    }

    @ViewBuilder private var findContent: some View {
        Section {
            if model.loadFailed {
                IssueText("Could not read History. Close this and try again.")
            } else if model.snapshot == nil {
                ProgressView("Reading History…").controlSize(.small)
            } else if model.snapshot?.items.isEmpty == true {
                Text("No dictations yet.").font(.headline)
                Text("Dictations you make while History is on will appear here, and you can search them later. You can still add replacements yourself in Automatic Replacements.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureSection(isExpanded: $searchExpanded) {
                    DisclosureSummaryLabel(title: "Search", summary: scopeSummary)
                } content: {
                    searchControls
                }
                .accessibilityIdentifier(IDs.scopeDisclosure)
                LabeledContent("Dictations to search") {
                    HStack(spacing: 8) {
                        Text("\(model.matchingCount)")
                        DataBoundaryBadge(label: "On this Mac")
                    }
                }
                coverageNotes
            }
            if !model.historyEnabled {
                Text("History is off, so new dictations are not saved. Dictations already stored can still be searched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        destinationSection
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Period", selection: $model.scope.period) {
                Text("Last 7 days").tag(HistorySearchScope.Period.days(7))
                Text("Last 30 days").tag(HistorySearchScope.Period.days(30))
                Text("Last 90 days").tag(HistorySearchScope.Period.days(90))
                Text("All available history").tag(HistorySearchScope.Period.all)
            }
            .accessibilityIdentifier(IDs.period)
            Picker("Speech model", selection: $model.scope.model) {
                Text("All speech models").tag(HistorySearchScope.Filter.all)
                ForEach(modelChoices, id: \.self) { name in
                    Text(name).tag(HistorySearchScope.Filter.named(name))
                }
            }
            .accessibilityIdentifier(IDs.speechModel)
            Text("These choices only change what is searched. They never change your speech model or where replacements are added.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var coverageNotes: some View {
        if model.withoutRecordedModel > 0 {
            Text("\(model.withoutRecordedModel) older \(model.withoutRecordedModel == 1 ? "dictation has" : "dictations have") no speech model recorded and \(model.withoutRecordedModel == 1 ? "is" : "are") searched only with All speech models.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let unreadable = model.snapshot?.unreadableLines, unreadable > 0 {
            IssueText("\(unreadable) History \(unreadable == 1 ? "entry" : "entries") could not be read and \(unreadable == 1 ? "is" : "are") not searched.", severity: .advisory)
        }
        if let days = model.snapshot?.unreadableFiles, days > 0 {
            IssueText("\(days) \(days == 1 ? "day" : "days") of History could not be read and \(days == 1 ? "is" : "are") not searched.", severity: .advisory)
        }
    }

    private var destinationSection: some View {
        Section {
            LabeledContent("Add replacements to", value: model.destinationName)
            Text(destinationScopeLine)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var destinationScopeLine: String {
        if case .mode = model.destination { return "Applies only in \(model.destinationName)." }
        return "Applies in modes that include Global replacements."
    }

    private var modelChoices: [String] {
        var names = model.recordedModels
        if case .named(let name) = model.scope.model, !names.contains(name) { names.append(name) }
        return names
    }

    private var scopeSummary: String {
        let period: String
        switch model.scope.period {
        case .days(let days): period = "Last \(days) days"
        case .all: period = "All available history"
        }
        let speech: String
        switch model.scope.model {
        case .all: speech = "All speech models"
        case .named(let name): speech = name
        }
        return "\(period) · All modes · \(speech)"
    }

    @ViewBuilder private var chooseContent: some View {
        Section {
            Text("Searched \(model.searchedCount) \(model.searchedCount == 1 ? "dictation" : "dictations") · \(scopeSummary)")
                .font(.caption).foregroundStyle(.secondary)
            if model.handledCount > 0 {
                Text("\(model.handledCount) similar \(model.handledCount == 1 ? "phrase is" : "phrases are") already corrected automatically and \(model.handledCount == 1 ? "is" : "are") not listed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if model.findings.isEmpty {
            Section {
                Text("No similar phrases found.").font(.headline)
                Text("Search compares spelling and rough sound, so it can miss a mishearing that is spelled very differently. Try searching more of your History.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.scope.period != .all {
                        Button("Search All Available History") { model.searchAllAvailableHistory() }
                            .accessibilityIdentifier(IDs.widenPeriod)
                    }
                }
            }
        } else {
            Section {
                Text("Selecting a phrase creates a replacement for every future match, not just the sentence shown.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.findings, id: \.key) { finding in
                    phraseRow(finding)
                }
            } header: {
                Text("Similar phrases")
            }
            destinationSection
        }
    }

    private func phraseRow(_ finding: AliasDiscovery.Finding) -> some View {
        Toggle(isOn: Binding(get: { model.isSelected(finding) }, set: { _ in model.toggle(finding) })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("“\(finding.phrase)” → \(model.word)").fontWeight(.medium)
                    Spacer()
                    Text(finding.occurrences.count == 1 ? "1 time" : "\(finding.occurrences.count) times")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let excerpt = model.excerpt(for: finding) {
                    excerptText(excerpt).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier(IDs.phrase(finding.key))
    }

    private func excerptText(_ excerpt: HistoryReplacementsModel.Excerpt) -> Text {
        Text(excerpt.before) + Text(excerpt.match).bold().foregroundColor(.primary) + Text(excerpt.after)
    }

    @ViewBuilder private var reviewContent: some View {
        if let preview = model.preview {
            Section {
                Text(reviewSummary(preview)).fontWeight(.medium)
                ForEach(preview.statuses.filter { !$0.isSaved }, id: \.phrase) { status in
                    IssueText(statusMessage(status), severity: .advisory)
                }
                ForEach(preview.statuses.filter { if case .overridesGlobal = $0.kind { true } else { false } }, id: \.phrase) { status in
                    Text(statusMessage(status)).font(.caption).foregroundStyle(.secondary)
                }
                Text("These are replacement effects on stored Heard text. History will not be changed. Future AI rewrites may still adjust the result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preview.effects.isEmpty {
                Section {
                    Text("No stored dictation would change. The replacements still apply to future dictations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(preview.effects.enumerated()), id: \.offset) { _, effect in
                        effectRow(effect)
                    }
                } header: {
                    Text("Changes in stored dictations")
                }
            }
        } else {
            Section {
                Text("Review these changes again before adding them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reviewSummary(_ preview: ReplacementPreview) -> String {
        let rules = preview.replacementCount == 1 ? "1 replacement" : "\(preview.replacementCount) replacements"
        guard preview.changeCount > 0 else { return "Adds \(rules) to \(model.destinationName)." }
        let places = preview.changeCount == 1 ? "1 place" : "\(preview.changeCount) places"
        let dictations = preview.affectedDictations == 1 ? "1 dictation" : "\(preview.affectedDictations) dictations"
        var line = "Adds \(rules) to \(model.destinationName). In stored dictations, this would change \(places) in \(dictations)"
        if preview.additionalMatches > 0 {
            line += ", including \(preview.additionalMatches) outside your search"
        }
        return line + "."
    }

    private func statusMessage(_ status: ReplacementPreview.PhraseStatus) -> String {
        switch status.kind {
        case .add: return ""
        case .alreadyAdded: return "“\(status.phrase)” already becomes \(model.word), so nothing is added for it."
        case .conflicts(let output):
            return "“\(status.phrase)” already becomes “\(output)”. It is not added; edit that replacement in Automatic Replacements to change it."
        case .overridesGlobal(let output):
            return "“\(status.phrase)” becomes “\(output)” from Global; in \(model.destinationName) it will become \(model.word) instead."
        }
    }

    private func effectRow(_ effect: ReplacementPreview.EntryEffect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if effect.isAdditional {
                    Text("Outside your search").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(effect.modeUnknown ? "\(effect.modeName) · mode not found" : effect.modeName)
                    .font(.caption).foregroundStyle(.secondary)
                if effect.wholeUtterance {
                    Text("Whole dictation is replaced").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(effect.changes.enumerated()), id: \.offset) { _, change in
                changeText(effect.currentText, change).font(.callout)
            }
        }
    }

    private func changeText(_ text: String, _ change: ReplacementPreview.Change) -> Text {
        let excerpt = HistoryReplacementsModel.excerpt(text, range: change.range)
        return Text(excerpt.before)
            + Text(change.before).strikethrough().foregroundColor(.secondary)
            + Text(" → ")
            + Text(change.after).bold()
            + Text(excerpt.after)
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if model.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            switch model.step {
            case .find:
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(IDs.cancel)
                Button("Find in History") { model.perform { await $0.find() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.matchingCount == 0)
                    .accessibilityIdentifier(IDs.find)
            case .choose:
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(IDs.cancel)
                Button("Back") { model.back() }
                    .accessibilityIdentifier(IDs.back)
                if model.selected.isEmpty, !model.findings.isEmpty {
                    Text("Select at least one phrase.").font(.caption).foregroundStyle(.secondary)
                }
                Button(model.selected.isEmpty ? "Review Changes" : "Review Changes (\(model.selected.count))") {
                    model.perform { await $0.review() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking || model.selected.isEmpty)
                .accessibilityIdentifier(IDs.review)
            case .review:
                Button("Back") { model.back() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(IDs.back)
                if let preview = model.preview {
                    Button(preview.replacementCount == 1 ? "Add 1 Replacement" : "Add \(preview.replacementCount) Replacements") {
                        model.perform { await $0.add() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || preview.replacementCount == 0)
                    .accessibilityIdentifier(IDs.add)
                } else {
                    Button("Review Again") { model.perform { await $0.review() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWorking || model.selected.isEmpty)
                        .accessibilityIdentifier(IDs.reviewAgain)
                }
            }
        }
    }
}
