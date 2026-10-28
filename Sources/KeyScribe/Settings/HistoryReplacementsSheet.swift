import SwiftUI
import KeyScribeKit

struct HistoryReplacementsSheet: View {
    @ObservedObject var model: HistoryReplacementsModel
    let onCancel: () -> Void
    @State private var searchExpanded = false
    @State private var combinedExpanded = false
    @State private var detailsExpanded = false
    @FocusState private var focusedPhrase: String?

    private typealias IDs = AccessibilityID.Settings.HistoryReplacements

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let one = model.singleSuggestion {
                    Text("Also correct “\(one.heard)” to “\(model.replacement)”?").font(.title2.bold())
                    Text("“\(model.word)” added.").foregroundStyle(.secondary)
                } else if model.offeredAfterAdding {
                    Text("“\(model.word)” added").font(.title2.bold())
                    Text("Also correct any of these spellings to “\(model.replacement)”?").foregroundStyle(.secondary)
                } else {
                    Text("Mishearings of “\(model.word)”").font(.title2.bold())
                    Text("Review similar phrases from saved History and choose which to correct.").foregroundStyle(.secondary)
                }
            }
            Form {
                Section {
                    if model.loadFailed {
                        IssueText("Could not read History. Refresh the search to try again.")
                        Button("Try Again") { model.searchAgain() }
                            .accessibilityIdentifier(IDs.retryLoad)
                    } else if model.snapshot == nil {
                        ProgressView("Searching History…").controlSize(.small)
                    } else {
                        if model.handledCount > 0, !model.phrases.isEmpty {
                            Text("\(model.handledCount) similar \(model.handledCount == 1 ? "phrase is" : "phrases are") already corrected automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.phrases.isEmpty, !model.isWorking {
                            Text(model.handledCount > 0
                                 ? "Similar phrases are already corrected automatically."
                                 : "No other spellings found in saved History yet.")
                                .font(.headline)
                            Text("When “\(model.word)” is misheard again, select those words in History and choose Add to Dictionary, or come back here with Review mishearings… beside the word. You can also enter a heard phrase yourself.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let one = model.singleSuggestion {
                            ForEach(Array(model.discoveryExcerpts(for: one.id).prefix(3).enumerated()), id: \.offset) { _, excerpt in
                                (Text("“" + excerpt.before) + Text(excerpt.match).bold() + Text(excerpt.after + "”"))
                                    .font(.callout)
                            }
                        } else {
                            ForEach(model.phrases) { phrase in
                                HistoryReplacementDraftRow(model: model, phrase: phrase, focus: $focusedPhrase)
                            }
                        }
                        if !model.phrases.isEmpty {
                            Text("Selected spellings will always become “\(model.replacement)” in this scope.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Add a phrase manually…") { model.addPhrase() }
                            .accessibilityIdentifier(IDs.addPhrase)
                    }
                }
                if let preview = model.preview, model.showsCombinedPreview {
                    Section {
                        DisclosureSection(isExpanded: $combinedExpanded) {
                            DisclosureSummaryLabel(title: "Combined preview", summary: combinedSummary(preview))
                        } content: {
                            ForEach(Array(preview.effects.enumerated()), id: \.offset) { _, effect in
                                HistoryReplacementEffectRow(effect: effect, changes: effect.changes)
                            }
                        }
                        .accessibilityIdentifier(IDs.combinedPreview)
                    }
                }
                Section {
                    DisclosureSection(
                        isExpanded: $detailsExpanded,
                        hasError: model.replacementIssue != nil
                    ) {
                        DisclosureSummaryLabel(title: "Replacement and scope", summary: "“\(model.replacement)” · \(model.destinationName)")
                    } content: {
                        VStack(alignment: .leading, spacing: 8) {
                            ReplacementValueField(
                                title: "Use instead", placeholder: "Text to insert", text: $model.replacement,
                                fieldID: IDs.useInstead)
                                .formFieldLabel("Use instead")
                            if let issue = model.replacementIssue {
                                IssueText(issue)
                            } else if let advisory = model.replacementAdvisory {
                                IssueText(advisory, severity: .advisory)
                            }
                            Text("Add to \(model.destinationName). \(destinationScopeLine)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                searchSection
            }
            .formStyle(.grouped)
            if let problem = model.problem {
                HStack {
                    IssueText(problem.message).accessibilityIdentifier(IDs.issue)
                    if problem.recovery == .refreshSearch {
                        Button("Refresh Search") { model.searchAgain() }
                            .accessibilityIdentifier(IDs.refresh)
                    }
                }
            } else if let notice = model.notice {
                IssueText(notice, severity: .advisory).accessibilityIdentifier(IDs.notice)
            }
            Text("Replaces future matches. Saved History stays unchanged. AI rewrites may still adjust the result.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                if model.singleSuggestion == nil {
                    Text(model.addGuidance).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.offeredAfterAdding ? "Not Now" : "Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(IDs.cancel)
                if let one = model.singleSuggestion {
                    Button("Correct “\(one.heard)”") { model.perform { await $0.confirmSingleSuggestion() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWorking || model.replacementIssue != nil)
                        .accessibilityIdentifier(IDs.add)
                } else {
                    Button(addTitle) { model.perform { await $0.add() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdd)
                        .accessibilityIdentifier(IDs.add)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 400, idealHeight: 560, maxHeight: 760)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IDs.sheet)
        .task(id: model.revision) {
            if model.snapshot != nil {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
            }
            await model.refresh()
        }
        .task(id: model.focusRequest) {
            guard let request = model.focusRequest else { return }
            await Task.yield()
            guard !Task.isCancelled, model.focusRequest == request else { return }
            focusedPhrase = request
            model.focusHandled(request)
        }
        .onDisappear { model.close() }
    }

    private var destinationScopeLine: String {
        if case .mode = model.destination { return "Applies only in \(model.destinationName)." }
        return "Applies in modes that include Global replacements."
    }

    private var addTitle: String {
        let count = model.preview?.replacementCount ?? 0
        return count == 0 ? "Add replacements" : "Add \(count) \(count == 1 ? "replacement" : "replacements")"
    }

    private func combinedSummary(_ preview: ReplacementPreview) -> String {
        let changes = "\(preview.changeCount) \(preview.changeCount == 1 ? "change" : "changes") in \(preview.affectedDictations) \(preview.affectedDictations == 1 ? "dictation" : "dictations")"
        let shared = model.unattributedChangeCount
        guard shared > 0 else { return changes }
        return changes + " · \(shared) not from a single phrase"
    }

    private var searchSection: some View {
        Section {
            DisclosureSection(isExpanded: $searchExpanded) {
                HStack {
                    DisclosureSummaryLabel(
                        title: "Search options",
                        summary: "\(scopeSummary) · \(model.searchedCount) dictations")
                    DataBoundaryBadge(label: "On this Mac")
                }
            } content: {
                Picker("Period", selection: $model.scope.period) {
                    Text("Last 7 days").tag(HistorySearchScope.Period.days(7))
                    Text("Last 30 days").tag(HistorySearchScope.Period.days(30))
                    Text("Last 90 days").tag(HistorySearchScope.Period.days(90))
                    Text("All saved History").tag(HistorySearchScope.Period.all)
                }
                .accessibilityIdentifier(IDs.period)
                Picker("Speech model", selection: $model.scope.model) {
                    Text("All speech models").tag(HistorySearchScope.Filter.all)
                    ForEach(modelChoices, id: \.self) { name in
                        Text(name).tag(HistorySearchScope.Filter.named(name))
                    }
                }
                .accessibilityIdentifier(IDs.speechModel)
                Button("Refresh search") { model.searchAgain() }
                    .accessibilityIdentifier(IDs.refreshSearch)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(IDs.scopeDisclosure)
            if let unreadable = model.snapshot?.unreadableLines, unreadable > 0 {
                IssueText("\(unreadable) History entries could not be read and are not searched.", severity: .advisory)
            }
            if let unreadable = model.snapshot?.unreadableFiles, unreadable > 0 {
                IssueText("\(unreadable) days of History could not be read and are not searched.", severity: .advisory)
            }
            if model.withoutRecordedModel > 0, model.scope.model != .all {
                Text("Older dictations without a recorded speech model are included only with All speech models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.historyEnabled {
                Text("History is off. Previously saved dictations can still be searched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
        case .all: period = "All saved History"
        }
        let speech: String
        switch model.scope.model {
        case .all: speech = "All speech models"
        case .named(let name): speech = name
        }
        return "\(period) · \(speech)"
    }
}

struct HistoryReplacementDraftRow: View {
    @ObservedObject var model: HistoryReplacementsModel
    let phrase: HistoryReplacementsModel.Phrase
    var focus: FocusState<String?>.Binding
    @State private var examplesExpanded = false

    private typealias IDs = AccessibilityID.Settings.HistoryReplacements

    var body: some View {
        let checked = model.isChecked(phrase.id)
        let effects = checked ? model.effects(for: phrase.id) : []
        let excerpts = checked ? [] : model.discoveryExcerpts(for: phrase.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { checked }, set: { _ in model.toggle(phrase.id) })) {
                    Text(phrase.isBlank ? "New phrase" : "“\(phrase.trimmed)” → \(ReplacementAuthoring.preview(for: model.replacement).text)")
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                .disabled(phrase.isBlank)
                .accessibilityIdentifier(IDs.phrase(phrase.id))
                Spacer()
                if let count = matchCount(checked: checked, effects: effects, excerpts: excerpts) {
                    Text(count).font(.caption).foregroundStyle(.secondary)
                }
                if phrase.discovered {
                    Button { model.toggleEditing(phrase.id) } label: {
                        Label("Edit heard phrase", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(IDs.editPhrase(phrase.id))
                }
            }
            if model.editing.contains(phrase.id) || !phrase.discovered {
                TextField("When heard", text: Binding(
                    get: { phrase.heard }, set: { model.updatePhrase(phrase.id, heard: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused(focus, equals: phrase.id)
                    .accessibilityIdentifier(IDs.heard(phrase.id))
                    .formFieldLabel("When heard")
            }
            if let issue = model.phraseIssue(phrase.id) { IssueText(issue) }
            if let status = model.status(for: phrase.id) { statusMessage(status) }
            if checked {
                checkedPreview(effects)
            } else if let first = excerpts.first {
                excerptText(first).font(.callout)
                if excerpts.count > 1 {
                    DisclosureSection("More examples (\(excerpts.count - 1))", isExpanded: $examplesExpanded) {
                        ForEach(Array(excerpts.dropFirst().enumerated()), id: \.offset) { _, excerpt in
                            excerptText(excerpt).font(.callout)
                        }
                    }
                    .accessibilityIdentifier(IDs.examples(phrase.id))
                }
            } else if !phrase.isBlank {
                Text("Select this phrase to preview its changes.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func matchCount(
        checked: Bool, effects: [HistoryReplacementsModel.RowEffect], excerpts: [HistoryReplacementsModel.Excerpt]
    ) -> String? {
        if checked {
            guard model.preview != nil, !model.isOnlyInCombinedPreview(phrase.id) else { return nil }
            let count = effects.reduce(0) { $0 + $1.changes.count }
            return "\(count) \(count == 1 ? "match" : "matches") in saved History"
        }
        guard !excerpts.isEmpty else { return nil }
        return "\(excerpts.count) \(excerpts.count == 1 ? "match" : "matches") in search"
    }

    @ViewBuilder private func checkedPreview(_ effects: [HistoryReplacementsModel.RowEffect]) -> some View {
        if model.preview == nil {
            Text("Updating the preview…").font(.caption).foregroundStyle(.secondary)
        } else if let first = effects.first {
            HistoryReplacementEffectRow(effect: first.effect, changes: first.changes)
            if effects.count > 1 {
                DisclosureSection("More examples (\(effects.count - 1))", isExpanded: $examplesExpanded) {
                    ForEach(Array(effects.dropFirst().enumerated()), id: \.offset) { _, row in
                        HistoryReplacementEffectRow(effect: row.effect, changes: row.changes)
                    }
                }
                .accessibilityIdentifier(IDs.examples(phrase.id))
            }
        } else if model.isOnlyInCombinedPreview(phrase.id) {
            Text("Its changes overlap other selected phrases. See Combined preview.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.status(for: phrase.id).map(isSaved) ?? false {
            Text("No matches in saved History. This replacement will apply to future dictations.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func isSaved(_ kind: ReplacementPreview.PhraseStatus.Kind) -> Bool {
        switch kind {
        case .add, .overridesGlobal: true
        case .alreadyAdded, .conflicts: false
        }
    }

    private func excerptText(_ excerpt: HistoryReplacementsModel.Excerpt) -> Text {
        Text(excerpt.before).foregroundColor(.secondary)
            + Text(excerpt.match).bold()
            + Text(excerpt.after).foregroundColor(.secondary)
    }

    @ViewBuilder private func statusMessage(_ kind: ReplacementPreview.PhraseStatus.Kind) -> some View {
        switch kind {
        case .add: EmptyView()
        case .alreadyAdded:
            Label("Already in Automatic Replacements.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .conflicts(let output):
            IssueText("Already becomes “\(ReplacementAuthoring.preview(for: output).text)”. This phrase will not be added. Edit its saved replacement to change it.", severity: .advisory)
        case .overridesGlobal(let output):
            IssueText("Overrides “\(ReplacementAuthoring.preview(for: output).text)” from Global in \(model.destinationName).", severity: .advisory)
        }
    }
}

private struct HistoryReplacementEffectRow: View {
    let effect: ReplacementPreview.EntryEffect
    let changes: [ReplacementPreview.Change]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(effect.modeUnknown ? "\(effect.modeName) · mode not found" : effect.modeName)
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                changeText(change).font(.callout)
            }
            if effect.wholeUtterance {
                Text("Replaces the whole dictation without an AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if effect.isAdditional {
                Text("Outside the search filters").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func changeText(_ change: ReplacementPreview.Change) -> Text {
        let excerpt = HistoryReplacementsModel.excerpt(effect.currentText, range: change.range)
        return Text(excerpt.before)
            + Text(change.before).strikethrough().foregroundColor(.secondary)
            + Text(" → ") + Text(change.after).bold() + Text(excerpt.after)
    }
}
