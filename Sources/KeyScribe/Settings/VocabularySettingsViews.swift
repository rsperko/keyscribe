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

struct HistoryReplacementsLauncher {
    let make: (
        _ word: String, _ destination: ReplacementPreview.Destination, _ destinationName: String,
        _ onSaved: @escaping (Int) -> Void
    ) -> HistoryReplacementsModel
}

struct DictionaryRows: View {
    let words: [String]
    let removeID: (String) -> String
    let deletionScope: VocabularyRemovalScope
    let deleteConfirmConfirmID: String
    let deleteConfirmCancelID: String
    var onFindReplacements: ((String) -> Void)? = nil
    var taughtSpellings: (String) -> [String] = { _ in [] }
    let onRemove: (String) -> Void

    var body: some View {
        ForEach(words, id: \.self) { word in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    if let onFindReplacements {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(word)
                                historyAction(word, action: onFindReplacements)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(word).fixedSize(horizontal: false, vertical: true)
                                historyAction(word, action: onFindReplacements)
                            }
                        }
                    } else {
                        Text(word).fixedSize(horizontal: false, vertical: true)
                    }
                    let spellings = taughtSpellings(word)
                    if !spellings.isEmpty {
                        Text("Also corrects \(spellings.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func historyAction(_ word: String, action: @escaping (String) -> Void) -> some View {
        Button("Review mishearings…") { action(word) }
            .font(.caption)
            .buttonStyle(.link)
            .accessibilityLabel("Find mishearings of \(word) in History")
            .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.findReplacementsForWord(word))
    }
}

struct ReplacementRows: View {
    let rules: [ReplacementsSet.Rule]
    let ids: ReplacementRowAccessibilityIDs
    let deletionScope: VocabularyRemovalScope
    @Binding var editingRule: ReplacementsSet.Rule?
    let onMove: (IndexSet, Int) -> Void
    let onRemove: (Int) -> Void
    var usageCaption: (ReplacementsSet.Rule) -> String? = { _ in nil }
    var usageHealth: (ReplacementsSet.Rule) -> [String] = { _ in [] }
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
                    Spacer(minLength: 12)
                    if let caption = usageCaption(rule) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(rule.heard)
                    .font(rule.regex ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text("Use instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ReplacementAuthoring.preview(for: rule.replace).text)
                    .textSelection(.enabled)
                    .lineLimit(1)
                if let advisory = ReplacementAuthoring.literalReturnMarkerAdvisory(replace: rule.replace, regex: rule.regex) {
                    IssueText(advisory, severity: .advisory, font: .caption)
                }
                if let advisory = ReplacementAuthoring.placeholderAdvisory(heard: rule.heard, replace: rule.replace, regex: rule.regex) {
                    IssueText(advisory, severity: .advisory, font: .caption)
                }
                ForEach(usageHealth(rule), id: \.self) { line in
                    IssueText(line, severity: .advisory, font: .caption)
                }
            }
            Spacer()
            Button { editingRule = rule } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit replacement")
            .accessibilityIdentifier(ids.edit(index))
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
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) {
            if index > rules.startIndex { Divider() }
        }
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
}

struct ReplacementEditorAccessibilityIDs {
    let heard: String
    let useInstead: String
    let regex: String
    let advanced: String
    let status: String
    let update: String
    let cancel: String

    static let vocabulary = ReplacementEditorAccessibilityIDs(
        heard: AccessibilityID.Settings.Vocabulary.replacementEditorHeard,
        useInstead: AccessibilityID.Settings.Vocabulary.replacementEditorUseInstead,
        regex: AccessibilityID.Settings.Vocabulary.replacementEditorRegex,
        advanced: AccessibilityID.Settings.Vocabulary.replacementEditorAdvanced,
        status: AccessibilityID.Settings.Vocabulary.replacementEditorStatus,
        update: AccessibilityID.Settings.Vocabulary.replacementEditorUpdate,
        cancel: AccessibilityID.Settings.Vocabulary.replacementEditorCancel)
}

// Presented as a sheet by the Vocabulary pane, never from the row: the rule's preview needs the width and
// height of a sheet, and a popover cannot host one without nesting scroll views.
struct ReplacementEditor: View {
    let rule: ReplacementsSet.Rule
    let ids: ReplacementEditorAccessibilityIDs
    let analyze: (VocabularyProposal) -> VocabularyAnalysis
    let onUpdate: (ReplacementsSet.Rule) -> Bool
    let onCancel: () -> Void
    let showsPreview: Bool
    @State private var heard: String
    @State private var replace: String
    @State private var regex: Bool
    @State private var wholeDictation: Bool
    @State private var advancedExpanded: Bool
    @State private var staleUpdate = false
    @State private var contentHeight: CGFloat = 0
    @StateObject private var preview: RulePreviewModel
    @FocusState private var heardFocused: Bool

    static let maxContentHeight: CGFloat = 420

    init(
        rule: ReplacementsSet.Rule,
        ids: ReplacementEditorAccessibilityIDs,
        previewSource: RulePreviewModel.Source?,
        analyze: @escaping (VocabularyProposal) -> VocabularyAnalysis,
        onUpdate: @escaping (ReplacementsSet.Rule) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.ids = ids
        self.analyze = analyze
        self.onUpdate = onUpdate
        self.onCancel = onCancel
        showsPreview = previewSource != nil
        _heard = State(initialValue: rule.heard)
        _replace = State(initialValue: rule.replace)
        _regex = State(initialValue: rule.regex)
        _wholeDictation = State(initialValue: rule.wholeDictation)
        _advancedExpanded = State(initialValue: false)
        _preview = StateObject(wrappedValue: RulePreviewModel(source: previewSource ?? .unavailable))
    }

    var body: some View {
        let draft = draft
        return VStack(alignment: .leading, spacing: 12) {
            Text("Edit Replacement").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Heard phrase")
                            TextField("Heard phrase", text: $heard, prompt: Text(regex ? "Regular expression" : "slash resume"))
                                .labelsHidden()
                                .multilineTextAlignment(.leading)
                                .textFieldStyle(.roundedBorder)
                                .font(regex ? .body.monospaced() : .body)
                                .frame(maxWidth: .infinity)
                                .focused($heardFocused)
                                .accessibilityIdentifier(ids.heard)
                        }
                        GridRow {
                            Text("Use instead")
                            VStack(alignment: .leading, spacing: 4) {
                                ReplacementValueField(
                                    title: "Use instead", placeholder: "Replacement text", text: $replace,
                                    fieldID: ids.useInstead)
                                    .frame(maxWidth: .infinity)
                                ReplacementExpandedEditorButton(
                                    title: "Use instead", placeholder: "Replacement text", text: $replace,
                                    ids: ReplacementExpandedEditorIDs(
                                        expand: AccessibilityID.Settings.Vocabulary.replacementEditorExpand,
                                        editor: AccessibilityID.Settings.Vocabulary.replacementEditorLarge,
                                        done: AccessibilityID.Settings.Vocabulary.replacementEditorLargeDone))
                            }
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(regex ? "Regular expression" : "Plain phrase").foregroundStyle(.secondary)
                                    Text("·").foregroundStyle(.secondary)
                                    Button(regex ? "Use a plain phrase" : "Use a regular expression") { regex.toggle() }
                                        .buttonStyle(.link)
                                        .accessibilityIdentifier(ids.regex)
                                }
                                if regex {
                                    Text("Use captures like $1 in Use instead.").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                    }
                    if showsPreview, let draftRule = draftRule(draft) {
                        RulePreviewSection(
                            model: preview, draft: draftRule, ids: AccessibilityID.Settings.Vocabulary.replacementEditorRule,
                            onUsePattern: { heard = $0 }, onMatchAlone: { wholeDictation = true })
                    }
                    DisclosureSection(isExpanded: $advancedExpanded) {
                        Text("Advanced").accessibilityIdentifier(ids.advanced)
                    } content: {
                        RuleScopePicker(wholeDictation: $wholeDictation, id: AccessibilityID.Settings.Vocabulary.replacementEditorRule.scope)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the focus ring, which the scroll view would otherwise clip.
                .padding(4)
                .padding(.trailing, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // As tall as the content up to a bound, so a short rule leaves no gap above the buttons and
            // expanded examples scroll inside the sheet instead of growing it past the window.
            .frame(height: min(max(contentHeight, 1), Self.maxContentHeight))
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
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(ids.cancel)
                Button("Save Changes", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canUpdate(draft))
                    .accessibilityIdentifier(ids.update)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear {
            heardFocused = true
            preview.update(draft: draftRule(draft), original: rule)
        }
        .onChange(of: draftRule(draft)) { _, current in preview.update(draft: current, original: rule) }
        .onDisappear { preview.close() }
    }

    private var draft: VocabularyDraftAnalysis {
        VocabularyDraftAnalysis(
            replacementTerm: heard, replacement: replace, regex: regex, analyze: analyze)
    }

    private func draftRule(_ draft: VocabularyDraftAnalysis) -> ReplacementsSet.Rule? {
        guard var rule = draft.replacementRule else { return nil }
        rule.wholeDictation = wholeDictation
        return rule
    }

    private func canUpdate(_ draft: VocabularyDraftAnalysis) -> Bool {
        guard let updated = draftRule(draft) else { return false }
        return updated != rule && !draft.hasReplacementIdentityConflict
    }

    private func commit() {
        let draft = draft
        guard canUpdate(draft), let updatedRule = draftRule(draft) else { return }
        staleUpdate = !onUpdate(updatedRule)
    }
}

struct VocabularyComposer: View {
    let analyze: (VocabularyProposal) -> VocabularyAnalysis
    let onAddWord: (String) -> Bool
    let onAddReplacement: (ReplacementsSet.Rule) -> Bool
    let existingRules: [ReplacementsSet.Rule]
    @StateObject private var preview: RulePreviewModel
    private let showsPreview: Bool
    @State private var heard = ""
    @State private var replace = ""
    @State private var regex = false
    @State private var chosenWholeDictation: Bool?
    @State private var advancedExpanded = false
    @FocusState private var focus: Field?

    init(
        analyze: @escaping (VocabularyProposal) -> VocabularyAnalysis,
        onAddWord: @escaping (String) -> Bool,
        onAddReplacement: @escaping (ReplacementsSet.Rule) -> Bool,
        existingRules: [ReplacementsSet.Rule] = [],
        previewSource: RulePreviewModel.Source? = nil
    ) {
        self.analyze = analyze
        self.onAddWord = onAddWord
        self.onAddReplacement = onAddReplacement
        self.existingRules = existingRules
        showsPreview = previewSource != nil
        _preview = StateObject(wrappedValue: RulePreviewModel(source: previewSource ?? .unavailable))
    }

    // A new rule that presses Return starts as a command; an update keeps the saved rule's choice. Either way
    // until the user picks otherwise.
    private var wholeDictation: Binding<Bool> {
        Binding(
            get: {
                chosenWholeDictation ?? existingRule?.wholeDictation
                    ?? ReplacementAuthoring.pressesReturn(replace: replace, regex: regex)
            },
            set: { chosenWholeDictation = $0 })
    }

    // The saved rule Add would update in place, matched the way ReplacementsSet.adding matches it.
    private var existingRule: ReplacementsSet.Rule? {
        let h = heardTrimmed
        return existingRules.first {
            $0.regex == regex && (regex ? $0.heard == h : $0.heard.caseInsensitiveCompare(h) == .orderedSame)
        }
    }

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
                    .labelsHidden()
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
            if let rule = draftRule(draft) {
                if showsPreview {
                    RulePreviewSection(
                        model: preview, draft: rule, ids: AccessibilityID.Settings.Vocabulary.composerRule,
                        onUsePattern: { heard = $0 }, onMatchAlone: { chosenWholeDictation = true })
                } else if let summary = ReplacementAuthoring.behaviorSummary(
                    replace: rule.replace, regex: rule.regex, wholeDictation: rule.wholeDictation) {
                    Text(summary).font(.callout)
                }
            }
            DisclosureSection("Advanced", isExpanded: advancedBinding) {
                Toggle("Match heard phrase as a regular expression", isOn: $regex)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerRegexToggle)
                if regex {
                    Text(regexHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draftRule(draft) != nil {
                    RuleScopePicker(wholeDictation: wholeDictation, id: AccessibilityID.Settings.Vocabulary.composerRule.scope)
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
        .onChange(of: draftRule(draft)) { _, current in
            if let current { preview.update(draft: current, original: existingRule) }
        }
    }

    private func draftRule(_ draft: VocabularyDraftAnalysis) -> ReplacementsSet.Rule? {
        guard case .replacement(let heard, let replace, let regex)? = draft.proposal else { return nil }
        return ReplacementsSet.Rule(heard: heard, replace: replace, regex: regex, wholeDictation: wholeDictation.wrappedValue)
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
        let saved = switch proposal {
        case .word(let word): onAddWord(word)
        case .replacement(let heard, let replace, let regex):
            onAddReplacement(ReplacementsSet.Rule(
                heard: heard, replace: replace, regex: regex, wholeDictation: wholeDictation.wrappedValue))
        }
        if saved { reset() }
    }

    private func reset() {
        heard = ""
        replace = ""
        regex = false
        chosenWholeDictation = nil
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
    var historyReplacements: HistoryReplacementsLauncher? = nil
    var rulePreviewSource: ((ReplacementPreview.Destination) -> RulePreviewModel.Source)? = nil
    @State private var selection: VocabularyScopeDestination = .global

    var body: some View {
        VStack(spacing: 0) {
            PaneNoticeBanner(notices: [dictionary.notice, replacements.notice, modes.notice].compactMap { $0 })
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
                dictionaryAdvice: dictionary.words.count >= Self.dictionaryAdviceThreshold
                    ? "You have \(dictionary.words.count) entries. That is fine — but a phrase \(Branding.appName) always mishears the same way works better as a Replacement, which changes it exactly."
                    : nil,
                historyReplacements: historyReplacements.map { launcher in
                    { word, onSaved in launcher.make(word, .global, "Global", onSaved) }
                },
                onAddWord: { dictionary.add($0) },
                onRemoveWord: dictionary.remove,
                onAddReplacement: { replacements.add(heard: $0.heard, replace: $0.replace, regex: $0.regex, wholeDictation: $0.wholeDictation) },
                onUpdateReplacement: replacements.update,
                rulePreviewSource: rulePreviewSource?(.global),
                onMoveReplacement: replacements.move,
                onRemoveReplacement: replacements.remove(at:),
                replacementUsageCaption: { replacements.usageCaption(for: $0, in: .global) },
                replacementUsageHealth: { replacements.usageHealth(for: $0, in: .global) })
        case let .mode(id):
            if let mode = modes.modes.first(where: { $0.id == id && $0.hasOwnVocabulary }) {
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
            wordsDescription: mode.runsVoiceCommands
                ? "App and place names \(Branding.appName) should recognize as written in a command."
                : "Names, product terms, and jargon \(Branding.appName) should recognize as written in this mode.",
            scope: scope,
            words: mode.dictionary.words,
            rules: mode.replacements.rules,
            deletionScope: .mode,
            historyReplacements: historyReplacements.map { launcher in
                { word, onSaved in launcher.make(word, .mode(mode.id), mode.name, onSaved) }
            },
            onAddWord: { word in
                var updated = mode
                updated.dictionary.words = DictionarySet(words: mode.dictionary.words).adding(word: word).words
                return modes.update(updated)
            },
            onRemoveWord: { word in
                var updated = mode
                updated.dictionary.words.removeAll { $0 == word }
                modes.update(updated)
            },
            onAddReplacement: { rule in
                var updated = mode
                updated.replacements.rules = ReplacementsSet(rules: mode.replacements.rules)
                    .adding(heard: rule.heard, replace: rule.replace, regex: rule.regex, wholeDictation: rule.wholeDictation).rules
                return modes.update(updated)
            },
            onUpdateReplacement: { original, replacement in
                let set = ReplacementsSet(rules: mode.replacements.rules).replacing(original, with: replacement)
                guard set.rules != mode.replacements.rules else { return false }
                var updated = mode
                updated.replacements.rules = set.rules
                return modes.update(updated)
            },
            rulePreviewSource: rulePreviewSource?(.mode(mode.id)),
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
            },
            replacementUsageCaption: { replacements.usageCaption(for: $0, in: .mode(mode.id)) },
            replacementUsageHealth: { replacements.usageHealth(for: $0, in: .mode(mode.id)) })
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
    var dictionaryAdvice: String? = nil
    var historyReplacements: ((String, @escaping (Int) -> Void) -> HistoryReplacementsModel)? = nil
    let onAddWord: (String) -> Bool
    let onRemoveWord: (String) -> Void
    let onAddReplacement: (ReplacementsSet.Rule) -> Bool
    let onUpdateReplacement: (ReplacementsSet.Rule, ReplacementsSet.Rule) -> Bool
    var rulePreviewSource: RulePreviewModel.Source? = nil
    let onMoveReplacement: (IndexSet, Int) -> Void
    let onRemoveReplacement: (Int) -> Void
    var replacementUsageCaption: (ReplacementsSet.Rule) -> String? = { _ in nil }
    var replacementUsageHealth: (ReplacementsSet.Rule) -> [String] = { _ in [] }
    @State private var recognitionHelpExpanded = false
    @State private var discovery: HistoryReplacementsModel?
    @State private var addedMessage: String?
    @State private var editingRule: ReplacementsSet.Rule?

    var body: some View {
        Form {
            Section {
                PaneDetailHeader(systemImage: "text.book.closed", title: title, subtitle: subtitle)
            }
            Section("Add to Vocabulary") {
                VocabularyComposer(
                    analyze: { [scope] in VocabularyAdvisor.analyze($0, in: scope) },
                    onAddWord: { word in
                        guard onAddWord(word) else { return false }
                        offerMishearings(of: word)
                        return true
                    },
                    onAddReplacement: onAddReplacement,
                    existingRules: rules,
                    previewSource: rulePreviewSource)
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
                    onFindReplacements: findAction,
                    taughtSpellings: { [scope] in scope.taughtSpellings(of: $0) },
                    onRemove: onRemoveWord)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.dictionaryList)
                if let dictionaryAdvice {
                    Label(dictionaryAdvice, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
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
                        deleteConfirmCancel: AccessibilityID.Settings.Vocabulary.replacementDeleteConfirmCancel),
                    deletionScope: deletionScope,
                    editingRule: $editingRule,
                    onMove: onMoveReplacement,
                    onRemove: onRemoveReplacement,
                    usageCaption: replacementUsageCaption,
                    usageHealth: replacementUsageHealth)
                if let rulePreviewSource, rulePreviewSource.history != nil, !rules.isEmpty {
                    RuleAuditSection(source: rulePreviewSource, rules: rules) { editingRule = $0 }
                }
                if let addedMessage {
                    Label(addedMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.replacementsAdded)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .sheet(isPresented: Binding(get: { editingRule != nil }, set: { if !$0 { editingRule = nil } })) {
            if let rule = editingRule {
                ReplacementEditor(
                    rule: rule, ids: .vocabulary, previewSource: rulePreviewSource,
                    analyze: { analyzeReplacementEdit(rule, $0) },
                    onUpdate: { updated in
                        guard onUpdateReplacement(rule, updated) else { return false }
                        editingRule = nil
                        return true
                    },
                    onCancel: { editingRule = nil })
            }
        }
        .sheet(item: $discovery, onDismiss: { discovery?.close() }) { model in
            HistoryReplacementsSheet(model: model) {
                model.close()
                discovery = nil
            }
        }
    }

    private var findAction: ((String) -> Void)? {
        guard historyReplacements != nil else { return nil }
        return { word in openDiscovery(word) }
    }

    private func openDiscovery(_ word: String) {
        addedMessage = nil
        discovery = makeDiscovery(word)
    }

    private func makeDiscovery(_ word: String) -> HistoryReplacementsModel? {
        historyReplacements?(word) { count in
            discovery?.close()
            discovery = nil
            addedMessage = count == 1 ? "Added 1 replacement" : "Added \(count) replacements"
        }
    }

    // A new word is checked against History straight away, so the spellings it was already misheard as are
    // offered in the same step. Nothing opens when History holds no likely mishearing.
    private func offerMishearings(of word: String) {
        guard discovery == nil, let model = makeDiscovery(word) else { return }
        model.offeredAfterAdding = true
        Task {
            await model.refresh()
            if model.findings.isEmpty || discovery != nil {
                model.close()
            } else {
                addedMessage = nil
                discovery = model
            }
        }
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
    @Published private(set) var loadNotice: PaneNotice?
    @Published private(set) var operationNotice: PaneNotice?
    private var operationFailedReading = false
    var notice: PaneNotice? { operationNotice ?? loadNotice }

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
        loadNotice = Self.loadNotice(DictionaryStore.load(supportDir: repository.supportDir), repository: repository)
        if loadNotice == nil, operationFailedReading { operationNotice = nil }
    }

    private static func loadNotice(_ load: ConfigLoad<DictionarySet>, repository: ConfigRepository) -> PaneNotice? {
        guard case .failed(let error) = load else { return nil }
        return .unreadableFile(
            DictionaryStore.fileName, error: error,
            file: repository.supportDir.appendingPathComponent(DictionaryStore.fileName),
            stillRunning: stillRunning(repository),
            here: "Global words can’t be shown or changed here until then.")
    }

    private static func stillRunning(_ repository: ConfigRepository) -> String? {
        PaneNotice.stillRunning(
            repository.runningState(of: DictionaryStore.fileName),
            working: "Your existing words are still working.", off: "Its words are off until it’s fixed.")
    }

    @discardableResult
    func add(_ word: String) -> Bool {
        mutate("“\(word)” wasn’t added") { $0.adding(word: word) }
    }

    func remove(_ word: String) {
        mutate("“\(word)” wasn’t removed") { $0.removing(word: word) }
    }

    // Reads-modifies-writes from disk (not from `@Published words`), since the global Add-to-Vocabulary
    // hotkey writes through the same repository while this pane is open — mutating stale in-memory state
    // would silently drop a word it just added.
    @discardableResult
    private func mutate(_ title: String, _ transform: (DictionarySet) -> DictionarySet) -> Bool {
        isApplyingLocalMutation = true
        defer { isApplyingLocalMutation = false }
        do {
            words = try repository.mutateDictionary(transform).words
            operationNotice = nil
            loadNotice = nil
            return true
        } catch {
            operationFailedReading = error is ConfigError
            operationNotice = .failure(
                title, error: error,
                file: repository.supportDir.appendingPathComponent(DictionaryStore.fileName),
                relativePath: DictionaryStore.fileName, stillRunning: Self.stillRunning(repository))
            return false
        }
    }
}

@MainActor
final class ReplacementsSettingsModel: ObservableObject {
    @Published private(set) var rules: [ReplacementsSet.Rule] = []
    @Published private(set) var usage = ReplacementUsage()
    @Published private(set) var loadNotice: PaneNotice?
    @Published private(set) var operationNotice: PaneNotice?
    private var operationFailedReading = false
    var notice: PaneNotice? { operationNotice ?? loadNotice }

    private let repository: ConfigRepository
    private var isApplyingLocalMutation = false
    private var usageObserver: NSObjectProtocol?

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
        usageObserver = NotificationCenter.default.addObserver(
            forName: .replacementUsageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUsage() }
        }
    }

    func refreshUsage() {
        usage = repository.replacementUsage?.snapshot() ?? ReplacementUsage()
    }

    func reload() {
        rules = repository.replacementRules()
        usage = repository.replacementUsage?.snapshot() ?? ReplacementUsage()
        if case .failed(let error) = ReplacementsStore.load(supportDir: repository.supportDir) {
            loadNotice = .unreadableFile(
                ReplacementsStore.fileName, error: error, file: replacementsFile, stillRunning: stillRunning,
                here: "Global replacements can’t be shown or changed here until then.")
        } else {
            loadNotice = nil
            if operationFailedReading { operationNotice = nil }
        }
    }

    private var replacementsFile: URL { repository.supportDir.appendingPathComponent(ReplacementsStore.fileName) }

    private var stillRunning: String? {
        PaneNotice.stillRunning(
            repository.runningState(of: ReplacementsStore.fileName),
            working: "Your existing replacements are still working.",
            off: "Its replacements are off until it’s fixed.")
    }

    func usageCaption(for rule: ReplacementsSet.Rule, in origin: ReplacementOrigin) -> String? {
        ReplacementUsageCaption.text(
            for: usage.entry(for: rule, in: origin), trackingSince: usage.trackingSince,
            today: HistoryStore.todayString())
    }

    func usageHealth(for rule: ReplacementsSet.Rule, in origin: ReplacementOrigin) -> [String] {
        ReplacementUsageCaption.health(for: usage.entry(for: rule, in: origin), rule: rule)
    }

    @discardableResult
    func add(heard: String, replace: String, regex: Bool, wholeDictation: Bool = false) -> Bool {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mutate("Replacement wasn’t saved") { set in
            set = set.adding(heard: trimmed, replace: replace, regex: regex, wholeDictation: wholeDictation)
        }
    }

    func remove(at index: Int) {
        guard rules.indices.contains(index) else { return }
        let target = rules[index]
        mutate("Replacement wasn’t removed") { set in
            if let i = set.rules.firstIndex(of: target) { set.rules.remove(at: i) }
        }
    }

    @discardableResult
    func update(_ original: ReplacementsSet.Rule, to updated: ReplacementsSet.Rule) -> Bool {
        var didUpdate = false
        let saved = mutate("Change wasn’t saved") { set in
            let replacement = set.replacing(original, with: updated)
            didUpdate = replacement != set
            set = replacement
        }
        return saved && didUpdate
    }

    func move(from source: IndexSet, to destination: Int) {
        guard ReplacementMoveValidation.isValid(source: source, destination: destination, count: rules.count)
        else { return }
        var ordered = rules
        ordered.move(fromOffsets: source, toOffset: destination)
        mutate("New order wasn’t saved") { set in
            set = set.reordering(ordered)
        }
    }

    // See DictionarySettingsModel.mutate. `remove(at:)` resolves the displayed row to a rule value first,
    // then removes the matching rule from the freshly-read set, so a rule the global hotkey appended
    // concurrently is preserved.
    @discardableResult
    private func mutate(_ title: String, _ transform: (inout ReplacementsSet) -> Void) -> Bool {
        isApplyingLocalMutation = true
        defer { isApplyingLocalMutation = false }
        do {
            rules = try repository.mutateReplacements(transform).rules
            operationNotice = nil
            loadNotice = nil
            return true
        } catch {
            operationFailedReading = error is ConfigError
            operationNotice = .failure(
                title, error: error, file: replacementsFile,
                relativePath: ReplacementsStore.fileName, stillRunning: stillRunning)
            return false
        }
    }
}
