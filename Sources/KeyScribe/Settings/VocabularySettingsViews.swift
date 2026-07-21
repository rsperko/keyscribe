import AppKit
import SwiftUI
import KeyScribeKit

enum VocabularyRemovalScope {
    case global
    case mode
}

struct VocabularyRemovalCopy {
    let title: String
    let message: String

    static func dictionary(_ word: String, scope: VocabularyRemovalScope) -> Self {
        switch scope {
        case .global:
            Self(
                title: "Remove “\(word)” from Words to Recognize?",
                message: "This word will no longer help recognition or AI rewrites. This cannot be undone.")
        case .mode:
            Self(
                title: "Remove “\(word)” from this mode?",
                message: "This mode-only word will be removed. This cannot be undone.")
        }
    }

    static func replacement(_ heard: String, scope: VocabularyRemovalScope) -> Self {
        switch scope {
        case .global:
            Self(
                title: "Delete the replacement for “\(heard)”?",
                message: "This replacement will no longer be applied. This cannot be undone.")
        case .mode:
            Self(
                title: "Delete the replacement for “\(heard)” from this mode?",
                message: "This mode-only replacement will be removed. This cannot be undone.")
        }
    }
}

struct DictionaryRows: View {
    let words: [String]
    let removeID: (String) -> String
    let deletionScope: VocabularyRemovalScope
    let deleteConfirmConfirmID: String
    let deleteConfirmCancelID: String
    let onRemove: (String) -> Void

    var body: some View {
        ForEach(words, id: \.self) { word in
            HStack {
                Text(word)
                Spacer()
                RemoveButton(
                    confirmation: VocabularyRemovalCopy.dictionary(word, scope: deletionScope),
                    accessibilityLabel: "Delete word",
                    confirmID: deleteConfirmConfirmID,
                    cancelID: deleteConfirmCancelID
                ) { onRemove(word) }
                    .accessibilityIdentifier(removeID(word))
            }
        }
    }
}

struct ReplacementRows: View {
    let rules: [ReplacementsSet.Rule]
    let ids: ReplacementRowAccessibilityIDs
    let deletionScope: VocabularyRemovalScope
    let analyzeEdit: (ReplacementsSet.Rule, VocabularyProposal) -> VocabularyAnalysis
    let onUpdate: (ReplacementsSet.Rule, ReplacementsSet.Rule) -> Bool
    let onMove: (IndexSet, Int) -> Void
    let onRemove: (Int) -> Void
    @State private var editingRule: ReplacementsSet.Rule?
    @State private var tableHeight: CGFloat = 76

    var body: some View {
        if !rules.isEmpty {
            ReplacementTable(
                rows: rules.indices.map { AnyView(replacementRow(at: $0)) },
                listID: ids.list,
                height: $tableHeight,
                onMove: onMove
            )
            .frame(height: tableHeight)
        }
    }

    private func replacementRow(at index: Int) -> some View {
        let rule = rules[index]
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 24)
                .accessibilityLabel("Drag to reorder")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.regex ? "Pattern" : "When heard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if rule.regex {
                        Text("Regex")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(rule.heard)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text("Use instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ReplacementAuthoring.preview(for: rule.replace).text)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { editingRule = rule } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit replacement")
            .accessibilityIdentifier(ids.edit(index))
            .popover(isPresented: Binding(
                get: { editingRule == rule },
                set: { if !$0, editingRule == rule { editingRule = nil } })) {
                    ReplacementEditor(
                        rule: rule,
                        ids: ids.editor,
                        analyze: { analyzeEdit(rule, $0) }) { updated in
                            guard onUpdate(rule, updated) else { return false }
                            editingRule = nil
                            return true
                        }
                }
            RemoveButton(
                confirmation: VocabularyRemovalCopy.replacement(rule.heard, scope: deletionScope),
                accessibilityLabel: "Delete replacement",
                confirmID: ids.deleteConfirmConfirm,
                cancelID: ids.deleteConfirmCancel
            ) { onRemove(index) }
                .accessibilityIdentifier(ids.remove(index))
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu {
            Button("Move up") { onMove(IndexSet(integer: index), index - 1) }
                .disabled(index == rules.startIndex)
            Button("Move down") { onMove(IndexSet(integer: index), index + 2) }
                .disabled(index == rules.index(before: rules.endIndex))
        }
        .accessibilityAction(named: Text("Move up")) {
            guard index > rules.startIndex else { return }
            onMove(IndexSet(integer: index), index - 1)
        }
        .accessibilityAction(named: Text("Move down")) {
            guard index < rules.index(before: rules.endIndex) else { return }
            onMove(IndexSet(integer: index), index + 2)
        }
    }

}

enum ReplacementDropValidation {
    static func isValid(source: Int, proposedRow: Int) -> Bool {
        proposedRow != source && proposedRow != source + 1
    }
}

enum ReplacementMoveValidation {
    static func isValid(source: IndexSet, destination: Int, count: Int) -> Bool {
        !source.isEmpty
            && source.allSatisfy { (0..<count).contains($0) }
            && (0...count).contains(destination)
    }
}

private struct ReplacementTable: NSViewRepresentable {
    let rows: [AnyView]
    let listID: String
    @Binding var height: CGFloat
    let onMove: (IndexSet, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = HandleDragTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("replacement"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .plain
        tableView.headerView = nil
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 76
        tableView.verticalMotionCanBeginDrag = true
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = PassThroughScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.setAccessibilityIdentifier(listID)
        context.coordinator.observeFrameChanges(of: tableView)
        context.coordinator.refreshLayout(of: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let previousRowCount = context.coordinator.parent.rows.count
        context.coordinator.parent = self
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        guard previousRowCount == rows.count else {
            tableView.reloadData()
            context.coordinator.refreshLayout(of: tableView)
            return
        }
        for row in rows.indices {
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? ReplacementTableCellView
            cell?.set(rootView: rows[row])
        }
        context.coordinator.refreshLayout(of: tableView)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ReplacementTable
        var rowHeights: [CGFloat] = []
        var frameObserver: ReplacementTableFrameObserver?

        init(parent: ReplacementTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func observeFrameChanges(of tableView: NSTableView) {
            frameObserver = ReplacementTableFrameObserver(view: tableView) { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                self.refreshLayout(of: tableView)
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rowHeights.indices.contains(row) ? rowHeights[row] : tableView.rowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("replacementRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? ReplacementTableCellView ?? ReplacementTableCellView()
            cell.identifier = identifier
            cell.set(rootView: parent.rows[row])
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .string)
            return item
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) === tableView,
                  let value = info.draggingPasteboard.string(forType: .string),
                  let source = Int(value)
            else { return [] }

            let proposedRow = dropOperation == .on && source < row ? row + 1 : row
            guard ReplacementDropValidation.isValid(source: source, proposedRow: proposedRow)
            else { return [] }
            tableView.setDropRow(proposedRow, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let value = info.draggingPasteboard.string(forType: .string),
                  let source = Int(value),
                  ReplacementDropValidation.isValid(source: source, proposedRow: row)
            else { return false }
            parent.onMove(IndexSet(integer: source), row)
            return true
        }

        func refreshLayout(of tableView: NSTableView) {
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                tableView.layoutSubtreeIfNeeded()
                guard tableView.bounds.width > 0 else { return }
                self.rowHeights = self.parent.rows.map { row in
                    NSHostingController(rootView: row).sizeThatFits(in: CGSize(
                        width: tableView.bounds.width,
                        height: CGFloat.greatestFiniteMagnitude)).height
                }
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(self.parent.rows.indices))
                tableView.layoutSubtreeIfNeeded()
                let height = tableView.numberOfRows == 0
                    ? CGFloat.zero
                    : tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
                guard abs(self.parent.height - height) > 0.5 else { return }
                self.parent.height = height
            }
        }
    }
}

@MainActor
final class ReplacementTableFrameObserver: NSObject {
    private weak var view: NSView?
    private let onWidthChange: () -> Void
    private var width: CGFloat

    init(view: NSView, onWidthChange: @escaping () -> Void) {
        self.view = view
        self.onWidthChange = onWidthChange
        self.width = view.frame.width
        super.init()
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: view)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func frameDidChange() {
        guard let view, view.frame.width != width else { return }
        width = view.frame.width
        onWidthChange()
    }
}

private final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class HandleDragTableView: NSTableView {
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        mouseDownPoint.x <= 24
    }
}

private final class ReplacementTableCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    func set(rootView: AnyView) {
        if let hostingView {
            hostingView.rootView = rootView
            return
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hostingView = hostingView
    }
}

struct ReplacementRowAccessibilityIDs {
    let list: String
    let edit: (Int) -> String
    let remove: (Int) -> String
    let deleteConfirmConfirm: String
    let deleteConfirmCancel: String
    let editor: ReplacementEditorAccessibilityIDs
}

struct ReplacementEditorAccessibilityIDs {
    let heard: String
    let useInstead: String
    let regex: String
    let advanced: String
    let status: String
    let update: String
}

private struct ReplacementEditor: View {
    let rule: ReplacementsSet.Rule
    let ids: ReplacementEditorAccessibilityIDs
    let analyze: (VocabularyProposal) -> VocabularyAnalysis
    let onUpdate: (ReplacementsSet.Rule) -> Bool
    @State private var heard: String
    @State private var replace: String
    @State private var regex: Bool
    @State private var advancedExpanded: Bool
    @State private var staleUpdate = false
    @FocusState private var heardFocused: Bool

    init(
        rule: ReplacementsSet.Rule,
        ids: ReplacementEditorAccessibilityIDs,
        analyze: @escaping (VocabularyProposal) -> VocabularyAnalysis,
        onUpdate: @escaping (ReplacementsSet.Rule) -> Bool
    ) {
        self.rule = rule
        self.ids = ids
        self.analyze = analyze
        self.onUpdate = onUpdate
        _heard = State(initialValue: rule.heard)
        _replace = State(initialValue: rule.replace)
        _regex = State(initialValue: rule.regex)
        _advancedExpanded = State(initialValue: rule.regex)
    }

    private var advancedBinding: Binding<Bool> {
        Binding(get: { advancedExpanded || regex }, set: { advancedExpanded = $0 })
    }

    var body: some View {
        let draft = draft
        return VStack(alignment: .leading, spacing: 12) {
            Text("Edit replacement").font(.headline)
            TextField(regex ? "Heard pattern" : "When heard", text: $heard)
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .focused($heardFocused)
                .accessibilityIdentifier(ids.heard)
            VStack(alignment: .leading, spacing: 4) {
                Text("Use instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReplacementTextEditor(
                    title: "Use instead",
                    placeholder: "Replacement text",
                    text: $replace,
                    editorID: ids.useInstead)
            }
            DisclosureSection(isExpanded: advancedBinding) {
                Text("Pattern matching")
                    .accessibilityIdentifier(ids.advanced)
            } content: {
                Toggle("Match heard phrase as a regular expression", isOn: $regex)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(ids.regex)
                if regex {
                    Text("Use captures like $1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
            }
            if let issue = draft.validationIssue {
                VocabularyDraftIssueText(issue: issue)
                    .accessibilityIdentifier(ids.status)
            } else if draft.hasReplacementIdentityConflict {
                IssueText("Another replacement already uses this heard phrase or pattern.")
                    .accessibilityIdentifier(ids.status)
            } else if staleUpdate {
                IssueText("This replacement changed elsewhere. Close this editor and try again.")
                    .accessibilityIdentifier(ids.status)
            } else if case let .advisory(message) = draft.feedback {
                IssueText(message, severity: .advisory)
                    .accessibilityIdentifier(ids.status)
            }
            HStack {
                Spacer()
                Button("Update", action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canUpdateReplacement(from: rule))
                    .accessibilityIdentifier(ids.update)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { heardFocused = true }
    }

    private var draft: VocabularyDraftAnalysis {
        VocabularyDraftAnalysis(
            replacementTerm: heard, replacement: replace, regex: regex, analyze: analyze)
    }

    private func commit() {
        let draft = draft
        guard draft.canUpdateReplacement(from: rule), let updatedRule = draft.replacementRule else { return }
        staleUpdate = !onUpdate(updatedRule)
    }
}

struct VocabularyComposer: View {
    let analyze: (VocabularyProposal) -> VocabularyAnalysis
    let onAddWord: (String) -> Void
    let onAddReplacement: (String, String, Bool) -> Void
    @State private var heard = ""
    @State private var replace = ""
    @State private var regex = false
    @State private var advancedExpanded = false
    @FocusState private var focus: Field?

    private enum Field { case heard, replace }

    // Stays open while regex is on — a collapsed section hiding an ON regex toggle would silently change
    // what Add does.
    private var advancedBinding: Binding<Bool> {
        Binding(get: { advancedExpanded || regex }, set: { advancedExpanded = $0 })
    }

    var body: some View {
        let draft = draft
        return VStack(alignment: .leading, spacing: 12) {
            LabeledContent {
                TextField(
                    "",
                    text: $heard,
                    prompt: Text(regex ? "Regular expression" : "e.g. Kubernetes"))
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .heard)
                    .onSubmit(commit)
                    .accessibilityLabel(regex ? "Heard pattern" : "Word or heard phrase")
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerTerm)
            } label: {
                Text(regex ? "Heard pattern" : "Word or heard phrase")
            }
            let replacementTitle = regex ? "Use instead" : "Use instead (optional)"
            let replacementPlaceholder = regex ? "Replacement text" : ""
            LabeledContent {
                VStack(alignment: .leading, spacing: 4) {
                    ReplacementValueField(
                        title: replacementTitle,
                        placeholder: replacementPlaceholder,
                        text: $replace,
                        fieldID: AccessibilityID.Settings.Vocabulary.composerUseInstead,
                        onSubmit: commit)
                    ReplacementExpandedEditorButton(
                        title: replacementTitle,
                        placeholder: replacementPlaceholder,
                        text: $replace,
                        ids: ReplacementExpandedEditorIDs(
                            expand: AccessibilityID.Settings.Vocabulary.composerUseInsteadExpand,
                            editor: AccessibilityID.Settings.Vocabulary.composerUseInsteadEditor,
                            done: AccessibilityID.Settings.Vocabulary.composerUseInsteadEditorDone))
                }
            } label: {
                Text(replacementTitle)
            }
            if !regex {
                Text(generalHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let feedback = draft.feedback {
                VocabularyFeedbackView(feedback: feedback)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerStatus)
            }
            DisclosureSection("Pattern matching", isExpanded: advancedBinding) {
                Toggle("Match heard phrase as a regular expression", isOn: $regex)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerRegexToggle)
                if regex {
                    Text(regexHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerAdvanced)
            if let issue = draft.validationIssue { VocabularyDraftIssueText(issue: issue) }
            HStack {
                Spacer()
                Button(action: commit) {
                    Label(draft.buttonTitle, systemImage: draft.isUpdate ? "pencil" : "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCommit)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerAdd)
            }
        }
        .onAppear { focus = .heard }
    }

    private var heardTrimmed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: VocabularyDraftAnalysis {
        VocabularyDraftAnalysis(term: heardTrimmed, replacement: replace, regex: regex, analyze: analyze)
    }

    private var generalHelpText: String {
        "Leave Use instead empty to add a word. Fill it in to create an automatic replacement."
    }

    private var regexHelpText: String {
        "Regex always creates a replacement, so Use instead is required. Use captures like $1."
    }

    private func commit() {
        guard draft.canCommit, let proposal = draft.proposal else { return }
        switch proposal {
        case .word(let word):
            onAddWord(word)
        case .replacement(let heard, let replace, let regex):
            onAddReplacement(heard, replace, regex)
        }
        reset()
    }

    private func reset() {
        heard = ""
        replace = ""
        regex = false
        advancedExpanded = false
        focus = .heard
    }
}

private struct RemoveButton: View {
    let confirmation: VocabularyRemovalCopy
    let accessibilityLabel: String
    let confirmID: String
    let cancelID: String
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Button(role: .destructive) {
            isConfirming = true
        } label: {
            Image(systemName: "trash")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .confirmationDialog(
            confirmation.title,
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: action)
                .accessibilityIdentifier(confirmID)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(cancelID)
        } message: {
            Text(confirmation.message)
        }
    }
}

struct VocabularySettingsView: View {
    // Placeholder until a WER benchmark measures where added entries start to hurt recognition on a
    // real-voice corpus; the nudge threshold should be set from that, not a borrowed number.
    static let dictionaryAdviceThreshold = 60

    @ObservedObject var dictionary: DictionarySettingsModel
    @ObservedObject var replacements: ReplacementsSettingsModel
    @ObservedObject var modes: ModesSettingsModel
    @Binding var navigationSelection: VocabularyScopeDestination
    @State private var selection: VocabularyScopeDestination = .global

    var body: some View {
        VStack(spacing: 0) {
            if let error = modes.error {
                IssueText(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            HStack(spacing: 0) {
                List(selection: $selection) {
                    Section {
                        PaneListRow(
                            title: "Global",
                            subtitle: VocabularyScopePicker.globalSummary(
                                words: dictionary.words, rules: replacements.rules))
                            .tag(VocabularyScopeDestination.global)
                            .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.global)
                    } header: {
                        PaneListSectionHeader("Everywhere")
                    }

                    if !sections.enabled.isEmpty {
                        Section {
                            ForEach(sections.enabled) { mode in
                                scopeRow(mode)
                            }
                        } header: {
                            PaneListSectionHeader("Enabled Modes")
                        }
                    }

                    if !sections.disabled.isEmpty {
                        Section {
                            ForEach(sections.disabled) { mode in
                                scopeRow(mode, disabled: true)
                            }
                        } header: {
                            PaneListSectionHeader("Disabled Modes")
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.scopeList)
                .frame(width: PaneMetrics.listWidth)

                Divider()

                selectedDetail
                    .id(resolvedSelection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            dictionary.reload()
            replacements.reload()
            modes.reload()
            synchronizeSelection(navigationSelection, in: modes.modes)
        }
        .onChange(of: selection) { _, current in
            synchronizeSelection(current, in: modes.modes)
        }
        .onChange(of: navigationSelection) { _, current in
            synchronizeSelection(current, in: modes.modes)
        }
        .onChange(of: modes.modes) { _, current in
            synchronizeSelection(selection, in: current)
        }
    }

    private var sections: VocabularyScopeSections {
        VocabularyScopePicker.sections(for: modes.modes)
    }

    private var resolvedSelection: VocabularyScopeDestination {
        VocabularyScopePicker.resolved(selection, in: modes.modes)
    }

    private func synchronizeSelection(_ requested: VocabularyScopeDestination, in modes: [Mode]) {
        let resolved = VocabularyScopePicker.resolved(requested, in: modes)
        if selection != resolved { selection = resolved }
        if navigationSelection != resolved { navigationSelection = resolved }
    }

    private func scopeRow(_ mode: Mode, disabled: Bool = false) -> some View {
        PaneListRow(title: mode.name, subtitle: VocabularyScopePicker.summary(for: mode), badges: {
            if disabled { PaneBadge("Disabled") }
        })
        .tag(VocabularyScopeDestination.mode(mode.id))
        .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.mode(mode.id))
    }

    @ViewBuilder private var selectedDetail: some View {
        switch resolvedSelection {
        case .global:
            VocabularyEditor(
                title: "Global Vocabulary",
                subtitle: "Applies in every mode unless that mode opts out.",
                wordsDescription: "Names, product terms, and jargon that should use your spelling everywhere.",
                scope: VocabularyScope(globalWords: dictionary.words, globalRules: replacements.rules),
                words: dictionary.words,
                rules: replacements.rules,
                deletionScope: .global,
                dictionaryError: dictionary.error,
                replacementsError: replacements.error,
                dictionaryAdvice: dictionary.words.count >= Self.dictionaryAdviceThreshold
                    ? "You have \(dictionary.words.count) entries. That is fine — but a phrase \(Branding.appName) always mishears the same way works better as a Replacement, which changes it exactly."
                    : nil,
                onAddWord: dictionary.add,
                onRemoveWord: dictionary.remove,
                onAddReplacement: { replacements.add(heard: $0, replace: $1, regex: $2) },
                onUpdateReplacement: replacements.update,
                onMoveReplacement: replacements.move,
                onRemoveReplacement: replacements.remove(at:))
        case let .mode(id):
            if let mode = modes.modes.first(where: { $0.id == id && !$0.isSystem }) {
                modeDetail(mode)
            } else {
                ContentUnavailableView(
                    "Choose a vocabulary scope", systemImage: "text.book.closed",
                    description: Text("Select Global or a mode to edit its vocabulary."))
            }
        }
    }

    private func modeDetail(_ mode: Mode) -> some View {
        let scope = VocabularyScope(
            globalWords: dictionary.words,
            globalRules: replacements.rules,
            local: VocabularyScope.Local(
                words: mode.dictionary.words,
                rules: mode.replacements.rules,
                includeGlobalWords: mode.dictionary.includeGlobal,
                includeGlobalRules: mode.replacements.includeGlobal))
        return VocabularyEditor(
            title: mode.name,
            subtitle: modeScopeDescription(mode),
            wordsDescription: "Names, product terms, and jargon \(Branding.appName) should recognize as written in this mode.",
            scope: scope,
            words: mode.dictionary.words,
            rules: mode.replacements.rules,
            deletionScope: .mode,
            onAddWord: { word in
                var updated = mode
                updated.dictionary.words = DictionarySet(words: mode.dictionary.words).adding(word: word).words
                modes.update(updated)
            },
            onRemoveWord: { word in
                var updated = mode
                updated.dictionary.words.removeAll { $0 == word }
                modes.update(updated)
            },
            onAddReplacement: { heard, replace, regex in
                var updated = mode
                updated.replacements.rules = ReplacementsSet(rules: mode.replacements.rules)
                    .adding(heard: heard, replace: replace, regex: regex).rules
                modes.update(updated)
            },
            onUpdateReplacement: { original, replacement in
                let set = ReplacementsSet(rules: mode.replacements.rules).replacing(original, with: replacement)
                guard set.rules != mode.replacements.rules else { return false }
                var updated = mode
                updated.replacements.rules = set.rules
                modes.update(updated)
                return true
            },
            onMoveReplacement: { source, destination in
                var rules = mode.replacements.rules
                guard ReplacementMoveValidation.isValid(source: source, destination: destination, count: rules.count)
                else { return }
                rules.move(fromOffsets: source, toOffset: destination)
                var updated = mode
                updated.replacements.rules = rules
                modes.update(updated)
            },
            onRemoveReplacement: { index in
                guard mode.replacements.rules.indices.contains(index) else { return }
                var updated = mode
                updated.replacements.rules.remove(at: index)
                modes.update(updated)
            })
    }

    private func modeScopeDescription(_ mode: Mode) -> String {
        switch (mode.dictionary.includeGlobal, mode.replacements.includeGlobal) {
        case (true, true): "Adds mode-only vocabulary on top of Global."
        case (false, false): "Uses only the vocabulary listed here."
        default: "Some Global vocabulary is included in this mode."
        }
    }
}

private struct VocabularyEditor: View {
    let title: String
    let subtitle: String
    let wordsDescription: String
    let scope: VocabularyScope
    let words: [String]
    let rules: [ReplacementsSet.Rule]
    let deletionScope: VocabularyRemovalScope
    var dictionaryError: String? = nil
    var replacementsError: String? = nil
    var dictionaryAdvice: String? = nil
    let onAddWord: (String) -> Void
    let onRemoveWord: (String) -> Void
    let onAddReplacement: (String, String, Bool) -> Void
    let onUpdateReplacement: (ReplacementsSet.Rule, ReplacementsSet.Rule) -> Bool
    let onMoveReplacement: (IndexSet, Int) -> Void
    let onRemoveReplacement: (Int) -> Void
    @State private var recognitionHelpExpanded = false

    var body: some View {
        Form {
            Section {
                PaneDetailHeader(systemImage: "text.book.closed", title: title, subtitle: subtitle)
            }
            Section("Add to Vocabulary") {
                VocabularyComposer(
                    analyze: { [scope] in VocabularyAdvisor.analyze($0, in: scope) },
                    onAddWord: onAddWord,
                    onAddReplacement: onAddReplacement)
            }
            Section("Words to Recognize") {
                Text(wordsDescription)
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureSection("How recognition works", isExpanded: $recognitionHelpExpanded) {
                    Text("Recognition support varies by speech model. These terms also guide a rewrite when one runs, including in privacy modes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.recognitionHelp)
                DictionaryRows(
                    words: words,
                    removeID: AccessibilityID.Settings.Vocabulary.dictionaryRemove,
                    deletionScope: deletionScope,
                    deleteConfirmConfirmID: AccessibilityID.Settings.Vocabulary.dictionaryDeleteConfirmConfirm,
                    deleteConfirmCancelID: AccessibilityID.Settings.Vocabulary.dictionaryDeleteConfirmCancel,
                    onRemove: onRemoveWord)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.dictionaryList)
                if let dictionaryAdvice {
                    Label(dictionaryAdvice, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let dictionaryError {
                    IssueText(dictionaryError)
                }
            }
            Section("Automatic Replacements") {
                Text("Changes a consistently misheard phrase to the text you want. Replacements happen before any AI rewrite, which may still adjust the result. When two rules could match, the longer phrase wins."
                    + (rules.count > 1 ? " If two match the same words, the higher one wins — drag to reorder." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                ReplacementRows(
                    rules: rules,
                    ids: ReplacementRowAccessibilityIDs(
                        list: AccessibilityID.Settings.Vocabulary.replacementsList,
                        edit: AccessibilityID.Settings.Vocabulary.replacementEdit,
                        remove: AccessibilityID.Settings.Vocabulary.replacementRemove,
                        deleteConfirmConfirm: AccessibilityID.Settings.Vocabulary.replacementDeleteConfirmConfirm,
                        deleteConfirmCancel: AccessibilityID.Settings.Vocabulary.replacementDeleteConfirmCancel,
                        editor: ReplacementEditorAccessibilityIDs(
                            heard: AccessibilityID.Settings.Vocabulary.replacementEditorHeard,
                            useInstead: AccessibilityID.Settings.Vocabulary.replacementEditorUseInstead,
                            regex: AccessibilityID.Settings.Vocabulary.replacementEditorRegex,
                            advanced: AccessibilityID.Settings.Vocabulary.replacementEditorAdvanced,
                            status: AccessibilityID.Settings.Vocabulary.replacementEditorStatus,
                            update: AccessibilityID.Settings.Vocabulary.replacementEditorUpdate)),
                    deletionScope: deletionScope,
                    analyzeEdit: analyzeReplacementEdit,
                    onUpdate: onUpdateReplacement,
                    onMove: onMoveReplacement,
                    onRemove: onRemoveReplacement)
                if let replacementsError {
                    IssueText(replacementsError)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    private func analyzeReplacementEdit(
        _ original: ReplacementsSet.Rule, _ proposal: VocabularyProposal
    ) -> VocabularyAnalysis {
        VocabularyAdvisor.analyze(
            proposal, in: VocabularyEditAnalysis.scope(for: scope, excluding: original))
    }
}

@MainActor
final class DictionarySettingsModel: ObservableObject {
    @Published private(set) var words: [String] = []
    @Published private(set) var error: String?

    private let repository: ConfigRepository
    private var isApplyingLocalMutation = false

    init(repository: ConfigRepository) {
        self.repository = repository
        reload()
        // The global Add-to-Vocabulary hotkey writes through the same repository while this pane is open;
        // reload on any external write so the list reflects the just-added entry without waiting for a
        // pane revisit. Skip the reentrant reload our own writes fire.
        repository.addChangeObserver { [weak self] in
            guard let self, !self.isApplyingLocalMutation else { return }
            self.reload()
        }
    }

    func reload() {
        words = repository.dictionaryWords()
        error = nil
    }

    func add(_ word: String) {
        mutate { $0.adding(word: word) }
    }

    func remove(_ word: String) {
        mutate { $0.removing(word: word) }
    }

    // Reads-modifies-writes from disk (not from `@Published words`), since the global Add-to-Vocabulary
    // hotkey writes through the same repository while this pane is open — mutating stale in-memory state
    // would silently drop a word it just added.
    private func mutate(_ transform: (DictionarySet) -> DictionarySet) {
        isApplyingLocalMutation = true
        defer { isApplyingLocalMutation = false }
        do {
            words = try repository.mutateDictionary(transform).words
            error = nil
        } catch {
            self.error = "Could not save the dictionary: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ReplacementsSettingsModel: ObservableObject {
    @Published private(set) var rules: [ReplacementsSet.Rule] = []
    @Published private(set) var error: String?

    private let repository: ConfigRepository
    private var isApplyingLocalMutation = false

    init(repository: ConfigRepository) {
        self.repository = repository
        reload()
        // The global Add-to-Vocabulary hotkey writes through the same repository while this pane is open;
        // reload on any external write so the list reflects the just-added rule without waiting for a
        // pane revisit. Skip the reentrant reload our own writes fire.
        repository.addChangeObserver { [weak self] in
            guard let self, !self.isApplyingLocalMutation else { return }
            self.reload()
        }
    }

    func reload() {
        rules = repository.replacementRules()
        error = nil
    }

    func add(heard: String, replace: String, regex: Bool) {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { set in
            set = set.adding(heard: trimmed, replace: replace, regex: regex)
        }
    }

    func remove(at index: Int) {
        guard rules.indices.contains(index) else { return }
        let target = rules[index]
        mutate { set in
            if let i = set.rules.firstIndex(of: target) { set.rules.remove(at: i) }
        }
    }

    @discardableResult
    func update(_ original: ReplacementsSet.Rule, to updated: ReplacementsSet.Rule) -> Bool {
        var didUpdate = false
        mutate { set in
            let replacement = set.replacing(original, with: updated)
            didUpdate = replacement != set
            set = replacement
        }
        return didUpdate
    }

    func move(from source: IndexSet, to destination: Int) {
        guard ReplacementMoveValidation.isValid(source: source, destination: destination, count: rules.count)
        else { return }
        var ordered = rules
        ordered.move(fromOffsets: source, toOffset: destination)
        mutate { set in
            set = set.reordering(ordered)
        }
    }

    // See DictionarySettingsModel.mutate. `remove(at:)` resolves the displayed row to a rule value first,
    // then removes the matching rule from the freshly-read set, so a rule the global hotkey appended
    // concurrently is preserved.
    private func mutate(_ transform: (inout ReplacementsSet) -> Void) {
        isApplyingLocalMutation = true
        defer { isApplyingLocalMutation = false }
        do {
            rules = try repository.mutateReplacements(transform).rules
            error = nil
        } catch {
            self.error = "Could not save replacements: \(error.localizedDescription)"
        }
    }
}
