import SwiftUI
import KeyScribeKit

// Names a new shared vocabulary, or renames one. The save returns a problem to show, or nil to close.
struct SharedVocabularyNameSheet: View {
    let title: String
    let confirmTitle: String
    let problem: (String) -> String?
    let onSave: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saveFailure: String?
    @FocusState private var focused: Bool

    init(
        title: String, confirmTitle: String, initialName: String = "",
        problem: @escaping (String) -> String?, onSave: @escaping (String) -> String?
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.problem = problem
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var issue: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : problem(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $name, prompt: Text("e.g. Programming"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.sharedName)
            }
            if let issue { IssueText(issue) }
            if let saveFailure { IssueText(saveFailure) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem(name) != nil)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.sharedNameSave)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear { focused = true }
    }

    private func save() {
        guard problem(name) == nil else { return }
        saveFailure = onSave(name)
        if saveFailure == nil { dismiss() }
    }
}

// Ticks the modes a shared vocabulary applies to. Cancel changes nothing; an empty choice is allowed. The
// sheet stays open with its choices until the whole change is saved.
struct SharedVocabularyModesSheet: View {
    let vocabularyName: String
    let modes: [Mode]
    let review: (Set<String>) -> AttachmentReview
    let onApply: (Set<String>, [String: PendingAttachment.Settlement]) -> PaneNotice?
    private let initial: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var choices: [String: SharedVocabularyMove.Entry] = [:]
    @State private var failure: PaneNotice?

    init(
        vocabularyName: String, modes: [Mode], selected: Set<String>,
        review: @escaping (Set<String>) -> AttachmentReview,
        onApply: @escaping (Set<String>, [String: PendingAttachment.Settlement]) -> PaneNotice?
    ) {
        self.vocabularyName = vocabularyName
        self.modes = modes
        self.review = review
        self.onApply = onApply
        initial = selected
        _selected = State(initialValue: selected)
    }

    var body: some View {
        let review = review(selected)
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Modes").font(.headline)
            Text("Selected modes use the words and replacements in \(vocabularyName). Future changes to this vocabulary apply to those modes too.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BoundedScroll {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(modes) { mode in
                        Toggle(isOn: binding(mode.id)) {
                            HStack(spacing: 6) {
                                Text(mode.name)
                                if !mode.enabled { PaneBadge("Disabled") }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(mode.enabled ? mode.name : "\(mode.name), disabled")
                        .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.sharedModeChoice(mode.id))
                    }
                    if let note = VocabularyScopePicker.detachNote(
                        modes: modes.filter { initial.contains($0.id) && !selected.contains($0.id) }.map(\.name),
                        vocabularies: [vocabularyName]) {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VocabularyConflictChoices(review: review, choices: $choices)
                }
            }
            if let failure { PaneNoticeRow(notice: failure) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use in Selected Modes") {
                    failure = onApply(selected, PendingAttachment.settlements(review.pending, choices: choices))
                    if failure == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(PendingAttachment.unsettled(review.pending, choices: choices))
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.sharedModesApply)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
}

// Ticks the shared vocabularies one mode uses, without leaving the mode.
struct ModeSharedVocabulariesSheet: View {
    let mode: Mode
    let vocabularies: [SharedVocabulary]
    let review: (Set<String>) -> AttachmentReview
    let onApply: (Set<String>, [String: PendingAttachment.Settlement]) -> PaneNotice?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var choices: [String: SharedVocabularyMove.Entry] = [:]
    @State private var failure: PaneNotice?

    init(
        mode: Mode, vocabularies: [SharedVocabulary],
        review: @escaping (Set<String>) -> AttachmentReview,
        onApply: @escaping (Set<String>, [String: PendingAttachment.Settlement]) -> PaneNotice?
    ) {
        self.mode = mode
        self.vocabularies = vocabularies
        self.review = review
        self.onApply = onApply
        _selected = State(initialValue: Set(mode.sharedVocabularies))
    }

    var body: some View {
        let review = review(selected)
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Shared Vocabulary").font(.headline)
            Text("\(mode.name) uses the words and replacements in the vocabularies you select, and keeps using them as they change. Its own entries still take priority.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BoundedScroll {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vocabularies) { vocabulary in
                        Toggle(isOn: binding(vocabulary.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(vocabulary.name)
                                Text(VocabularyScopePicker.sharedSummary(vocabulary)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.modeSharedChoice(vocabulary.id))
                    }
                    if let note = VocabularyScopePicker.detachNote(
                        modes: [mode.name],
                        vocabularies: vocabularies.filter {
                            mode.sharedVocabularies.contains($0.id) && !selected.contains($0.id)
                        }.map(\.name)) {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VocabularyConflictChoices(review: review, choices: $choices)
                }
            }
            if let failure { PaneNoticeRow(notice: failure) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Selected") {
                    failure = onApply(selected, PendingAttachment.settlements(review.pending, choices: choices))
                    if failure == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(PendingAttachment.unsettled(review.pending, choices: choices))
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.modeSharedApply)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
}

// Content that grows with what it holds until it reaches a height, then scrolls.
struct BoundedScroll<Content: View>: View {
    var maxHeight: CGFloat = 340
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            ScrollView { content().frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(maxHeight: maxHeight)
    }
}

// A disagreement among the shared vocabularies one mode would use, which that mode must settle.
struct PendingAttachment: Identifiable, Equatable {
    // The entries of a mode's own that settle its disagreements.
    struct Settlement: Equatable {
        var rules: [ReplacementsSet.Rule] = []
        var words: [String] = []
    }

    let mode: Mode
    let competition: SharedVocabularyConflicts.Competition
    var id: String { "\(mode.id)\u{0}\(competition.key)" }

    static func settlements(
        _ items: [PendingAttachment], choices: [String: SharedVocabularyMove.Entry]
    ) -> [String: Settlement] {
        var settlements: [String: Settlement] = [:]
        for item in items {
            guard let chosen = choices[item.id], item.competition.options.contains(where: { $0.entry == chosen }) else {
                continue
            }
            switch chosen {
            case .word(let word): settlements[item.mode.id, default: .init()].words.append(word)
            case .rule(let rule): settlements[item.mode.id, default: .init()].rules.append(rule)
            }
        }
        return settlements
    }

    static func unsettled(_ items: [PendingAttachment], choices: [String: SharedVocabularyMove.Entry]) -> Bool {
        items.contains { item in
            !item.competition.options.contains { option in choices[item.id].map { $0 == option.entry } ?? false }
        }
    }
}

// What a change would do to the modes it reaches: disagreements to settle, and Global entries it replaces.
struct AttachmentReview: Equatable {
    struct Change: Identifiable, Equatable {
        let modeName: String
        let vocabularyName: String
        let change: SharedVocabularyConflicts.Change
        var id: String { "\(modeName)\u{0}\(vocabularyName)\u{0}\(VocabularyConflictCopy.describe(change.proposed))" }
    }

    var pending: [PendingAttachment] = []
    var changes: [Change] = []
}

extension Mode {
    func settled(_ settlement: PendingAttachment.Settlement) -> Mode {
        var mode = addingReplacements(settlement.rules)
        mode.dictionary.words = settlement.words.reduce(DictionarySet(words: mode.dictionary.words)) { $0.adding(word: $1) }.words
        return mode
    }

    mutating func settle(_ settlement: PendingAttachment.Settlement) { self = settled(settlement) }

    mutating func setUsing(_ vocabularyId: String, _ uses: Bool) {
        if !uses {
            sharedVocabularies.removeAll { $0 == vocabularyId }
        } else if !sharedVocabularies.contains(vocabularyId) {
            sharedVocabularies.append(vocabularyId)
        }
    }
}

enum VocabularyConflictCopy {
    static func describe(_ entry: SharedVocabularyMove.Entry) -> String {
        switch entry {
        case .word(let word): "Spell it \u{201C}\(word)\u{201D}"
        case .rule(let rule):
            "Replace with \u{201C}\(ReplacementAuthoring.preview(for: rule.replace).text)\u{201D}"
        }
    }

    static func caption(_ option: SharedVocabularyConflicts.Option) -> String {
        let from = "From \(ListFormatter.localizedString(byJoining: option.sources))"
        guard case .rule(let rule) = option.entry else { return from }
        return from + " \u{00B7} " + (rule.wholeDictation ? "Only when said alone" : "Anywhere in a sentence")
    }

    static func heading(_ item: PendingAttachment) -> String {
        "\u{201C}\(item.competition.phrase)\u{201D} in \(item.mode.name)"
    }

    static func change(_ change: AttachmentReview.Change) -> String {
        let what: String = switch change.change.proposed {
        case .word(let word): "will be spelled \u{201C}\(word)\u{201D}"
        case .rule(let rule): "will become \u{201C}\(ReplacementAuthoring.preview(for: rule.replace).text)\u{201D}"
        }
        let phrase: String = switch change.change.current {
        case .word(let word): word
        case .rule(let rule): rule.heard
        }
        let before: String = switch change.change.current {
        case .word(let word): "\u{201C}\(word)\u{201D}"
        case .rule(let rule): "\u{201C}\(ReplacementAuthoring.preview(for: rule.replace).text)\u{201D}"
        }
        return "In \(change.modeName), \u{201C}\(phrase)\u{201D} \(what) from \(change.vocabularyName), instead of \(before) from Global."
    }
}

// A choice for each disagreement, stacked so the full output, its source, and where it acts stay readable.
struct VocabularyConflictChoices: View {
    let review: AttachmentReview
    @Binding var choices: [String: SharedVocabularyMove.Entry]

    var body: some View {
        if !review.pending.isEmpty || !review.changes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                if !review.pending.isEmpty {
                    IssueText(
                        "Shared vocabularies disagree here. Choose what each mode uses; your choice is saved as that mode\u{2019}s own entry and stays when the shared vocabularies change. To fix a shared entry instead, cancel and edit it.",
                        severity: .advisory)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(review.pending) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(VocabularyConflictCopy.heading(item)).font(.callout.weight(.semibold))
                        ForEach(Array(item.competition.options.enumerated()), id: \.offset) { _, option in
                            choice(item, option)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Choose for \(VocabularyConflictCopy.heading(item))")
                }
                ForEach(review.changes) { change in
                    Text(VocabularyConflictCopy.change(change))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func choice(_ item: PendingAttachment, _ option: SharedVocabularyConflicts.Option) -> some View {
        let chosen = choices[item.id] == option.entry
        return Button {
            choices[item.id] = option.entry
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(VocabularyConflictCopy.describe(option.entry))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(VocabularyConflictCopy.caption(option))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

// What a mode uses without listing it, each entry with where it comes from. Read-only: an inherited entry is
// edited in its own vocabulary, which its source name opens.
struct IncludedVocabularySection: View {
    let words: [VocabularyMerge.Included<String>]
    let rules: [VocabularyMerge.Included<ReplacementsSet.Rule>]
    let sourceName: (String?) -> String
    let onOpenSource: (String?) -> Void
    @State private var expanded = false

    var body: some View {
        if !words.isEmpty || !rules.isEmpty {
            Section {
                DisclosureSection(
                    "Included Vocabulary", isExpanded: $expanded,
                    headerID: AccessibilityID.Settings.Vocabulary.modeIncluded
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !words.isEmpty {
                            Text("Words to Recognize").font(.caption.weight(.semibold))
                            ForEach(Array(words.enumerated()), id: \.offset) { _, entry in
                                LabeledContent {
                                    source(entry.source)
                                } label: {
                                    Text(entry.value).textSelection(.enabled)
                                }
                            }
                        }
                        if !rules.isEmpty {
                            Text("Automatic Replacements").font(.caption.weight(.semibold))
                            ForEach(Array(rules.enumerated()), id: \.offset) { _, entry in
                                LabeledContent {
                                    source(entry.source)
                                } label: {
                                    IncludedRuleLabel(rule: entry.value)
                                }
                            }
                        }
                        Text("To change one, open where it comes from, or add an entry here to override it in this mode.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func source(_ id: String?) -> some View {
        let name = sourceName(id)
        return Button(name) { onOpenSource(id) }
            .buttonStyle(.link)
            .font(.caption)
            .help("Open \(name)")
            .accessibilityLabel("From \(name)")
            .accessibilityHint("Opens \(name)")
            .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.includedSource(id ?? "global"))
    }
}

// One inherited rule: what is heard, what it becomes, and where it acts. A value too long for the row expands in
// place, so the whole rule can be read without leaving the mode.
private struct IncludedRuleLabel: View {
    let rule: ReplacementsSet.Rule
    @State private var showsAll = false

    var body: some View {
        let preview = ReplacementAuthoring.preview(for: rule.replace)
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.regex ? "Pattern" : "When heard").font(.caption).foregroundStyle(.secondary)
            Text(rule.heard)
                .font(rule.regex ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .lineLimit(showsAll ? nil : 2)
            Text("Use instead").font(.caption).foregroundStyle(.secondary)
            Text(showsAll ? rule.replace : preview.text)
                .textSelection(.enabled)
                .lineLimit(showsAll ? nil : 1)
                .fixedSize(horizontal: false, vertical: showsAll)
            HStack(spacing: 6) {
                Text(rule.wholeDictation ? "Only when said alone" : "Anywhere in a sentence")
                if preview.isTruncated || rule.replace.contains(where: \.isNewline) {
                    Text("\u{00B7}")
                    Button(showsAll ? "Show Less" : "Show All") { showsAll.toggle() }
                        .buttonStyle(.link)
                        .accessibilityLabel(showsAll ? "Show less of the replacement" : "Show the whole replacement")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum MoveToSharedCopy {
    static func lines(
        _ entry: SharedVocabularyMove.Entry, plan: SharedVocabularyMove.Plan, vocabularyName: String, modeName: String
    ) -> [String] {
        let what = switch entry {
        case .word(let word): "\u{201C}\(word)\u{201D}"
        case .rule: "this replacement"
        }
        var lines = ["Move \(what) to \(vocabularyName)?"]
        let users = "\(vocabularyName) is used by \(ListFormatter.localizedString(byJoining: plan.users))."
        let audience = switch plan.users.count {
        case 0, 1: users
        case 2: users + " Future edits will apply to both."
        default: users + " Future edits will apply to all \(plan.users.count)."
        }
        lines.append(audience)
        if let added = plan.newlyIncluded, added.words + added.rules > 0 {
            let parts = [(added.words, "word"), (added.rules, "replacement")].filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            lines.append("\(modeName) will also start using the \(parts.joined(separator: " and ")) already in \(vocabularyName).")
        }
        return lines
    }
}


struct MoveToSharedRequest: Identifiable {
    let id = UUID()
    let mode: Mode
    let entry: SharedVocabularyMove.Entry
}

// Moves one of a mode's own entries into a shared vocabulary, new or existing. It says who will use the entry,
// what else the mode starts using, settles any disagreement it leaves in a mode, and refuses to overwrite a
// different entry already there.
struct MoveToSharedVocabularySheet: View {
    let request: MoveToSharedRequest
    let vocabularies: [SharedVocabulary]
    let modes: [Mode]
    let nameProblem: (String) -> String?
    let review: (SharedVocabularyMove.Entry, Mode, SharedVocabulary) -> AttachmentReview
    let onMove: (_ destination: String?, _ newName: String, [String: PendingAttachment.Settlement]) -> PaneNotice?
    @Environment(\.dismiss) private var dismiss
    @State private var destination: String?
    @State private var newName = ""
    @State private var choices: [String: SharedVocabularyMove.Entry] = [:]
    @State private var failure: PaneNotice?

    static let newVocabulary = "\u{0}new"

    init(
        request: MoveToSharedRequest, vocabularies: [SharedVocabulary], modes: [Mode],
        nameProblem: @escaping (String) -> String?,
        review: @escaping (SharedVocabularyMove.Entry, Mode, SharedVocabulary) -> AttachmentReview,
        onMove: @escaping (String?, String, [String: PendingAttachment.Settlement]) -> PaneNotice?
    ) {
        self.request = request
        self.vocabularies = vocabularies
        self.modes = modes
        self.nameProblem = nameProblem
        self.review = review
        self.onMove = onMove
        _destination = State(initialValue: vocabularies.first?.id ?? Self.newVocabulary)
    }

    private var creating: Bool { destination == Self.newVocabulary }

    private var target: SharedVocabulary? {
        if creating {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || nameProblem(name) != nil ? nil : SharedVocabulary(id: Self.newVocabulary, name: name)
        }
        return vocabularies.first { $0.id == destination }
    }

    var body: some View {
        let target = target
        let plan = target.map { SharedVocabularyMove.plan(request.entry, from: request.mode, to: $0, modes: modes) }
        let review = target.flatMap { plan?.conflict == nil ? self.review(request.entry, request.mode, $0) : nil }
            ?? AttachmentReview()
        VStack(alignment: .leading, spacing: 14) {
            Text("Move to Shared Vocabulary").font(.headline)
            Picker("Vocabulary", selection: $destination) {
                ForEach(vocabularies) { Text($0.name).tag(Optional($0.id)) }
                Text("New Shared Vocabulary\u{2026}").tag(Optional(Self.newVocabulary))
            }
            .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.moveSharedChoice)
            if creating {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $newName, prompt: Text("e.g. Programming"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.moveSharedName)
                    if !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let problem = nameProblem(newName) {
                        IssueText(problem)
                    }
                }
            }
            if let target, let plan {
                BoundedScroll {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(MoveToSharedCopy.lines(
                            request.entry, plan: plan, vocabularyName: target.name, modeName: request.mode.name), id: \.self
                        ) { line in
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        if let conflict = plan.conflict {
                            IssueText("\(conflict) Edit one of them first, so neither is overwritten.")
                        }
                        VocabularyConflictChoices(review: review, choices: $choices)
                    }
                }
            }
            if let failure { PaneNoticeRow(notice: failure) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") {
                    failure = onMove(
                        creating ? nil : destination, newName, PendingAttachment.settlements(review.pending, choices: choices))
                    if failure == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil || plan?.conflict != nil || PendingAttachment.unsettled(review.pending, choices: choices))
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.moveSharedApply)
            }
        }
        .padding(20).frame(width: 440)
    }
}
