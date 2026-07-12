import SwiftUI
import KeyScribeKit

struct DictionaryRows: View {
    let words: [String]
    let removeID: (String) -> String
    let onRemove: (String) -> Void

    var body: some View {
        ForEach(words, id: \.self) { word in
            HStack {
                Text(word)
                Spacer()
                RemoveButton { onRemove(word) }
                    .accessibilityIdentifier(removeID(word))
            }
        }
    }
}

struct ReplacementRows: View {
    let rules: [ReplacementsSet.Rule]
    let removeID: (Int) -> String
    let onRemove: (Int) -> Void

    var body: some View {
        ForEach(rules.indices, id: \.self) { index in
            let rule = rules[index]
            HStack(spacing: 6) {
                Text(rule.heard)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(rule.replace).foregroundStyle(.secondary)
                if rule.regex { Text("Regex").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                RemoveButton { onRemove(index) }
                    .accessibilityIdentifier(removeID(index))
            }
        }
    }
}

struct VocabularyComposer: View {
    let onAddWord: (String) -> Void
    let onAddReplacement: (String, String, Bool) -> Void
    @State private var heard = ""
    @State private var replace = ""
    @State private var regex = false
    @State private var advancedExpanded = false
    @FocusState private var focus: Field?

    private enum Field { case heard, replace }

    // The disclosure is open whenever the user opened it OR regex is on — a collapsed section hiding an ON
    // regex toggle would silently change what Add does (5a).
    private var advancedBinding: Binding<Bool> {
        Binding(get: { advancedExpanded || regex }, set: { advancedExpanded = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                regex ? "Heard pattern" : "Word or heard phrase",
                text: $heard,
                prompt: Text(regex ? "Regular expression" : "e.g. Kubernetes"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .heard)
                .onSubmit(commit)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerTerm)
            TextField(
                regex ? "Use instead" : "Use instead (optional)",
                text: $replace,
                prompt: regex ? Text("Replacement text") : nil)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .replace)
                .onSubmit(commit)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerUseInstead)
            if !regex {
                Text(generalHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            }
            .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerAdvanced)
            // Kept OUTSIDE the disclosure: it gates canAdd, so it must stay visible while regex is on even if
            // the section is somehow collapsed.
            if regexInvalid {
                IssueText("That is not a valid regular expression.")
            }
            HStack {
                Spacer()
                Button(action: commit) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.composerAdd)
            }
        }
        .onAppear { focus = .heard }
    }

    private var heardTrimmed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var replaceTrimmed: String { replace.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var regexInvalid: Bool {
        regex && !heardTrimmed.isEmpty && !RegexCache.isValidPattern(heardTrimmed)
    }
    private var canAdd: Bool { !heardTrimmed.isEmpty && (!regex || !replaceTrimmed.isEmpty) && !regexInvalid }

    private var generalHelpText: String {
        "Leave Use instead empty to add a word. Fill it in to create an automatic replacement."
    }

    private var regexHelpText: String {
        "Regex always creates a replacement, so Use instead is required. Use captures like $1."
    }

    private func commit() {
        guard canAdd else { return }
        if !regex && replaceTrimmed.isEmpty {
            onAddWord(heardTrimmed)
        } else {
            onAddReplacement(heardTrimmed, replaceTrimmed, regex)
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
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

struct VocabularySettingsView: View {
    // Placeholder until BiasBenchmark measures where added entries start to raise WER on the
    // real-voice corpus; the nudge threshold should be set from that, not a borrowed number.
    static let dictionaryAdviceThreshold = 60

    @ObservedObject var dictionary: DictionarySettingsModel
    @ObservedObject var replacements: ReplacementsSettingsModel

    var body: some View {
        Form {
            Section("Add to Vocabulary") {
                VocabularyComposer(
                    onAddWord: dictionary.add,
                    onAddReplacement: { replacements.add(heard: $0, replace: $1, regex: $2) })
            }
            Section("Words to Recognize") {
                Text("Names, product terms, and jargon. When you say one, \(Branding.appName) prefers your spelling — as it transcribes and when it cleans up afterward. Entries are shared with your AI service, marked as intended spellings rather than typos, whenever a rewrite runs — including in privacy modes.")
                    .font(.caption).foregroundStyle(.secondary)
                DictionaryRows(
                    words: dictionary.words,
                    removeID: AccessibilityID.Settings.Vocabulary.dictionaryRemove,
                    onRemove: dictionary.remove)
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.dictionaryList)
                if dictionary.words.count >= Self.dictionaryAdviceThreshold {
                    Label("You have \(dictionary.words.count) entries. That is fine — but a phrase \(Branding.appName) always mishears the same way works better as a Replacement, which changes it exactly.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = dictionary.error {
                    IssueText(error)
                }
            }
            Section("Automatic Replacements") {
                Text("Changes a consistently misheard phrase to the text you want. Replacements run before any AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
                ReplacementRows(
                    rules: replacements.rules,
                    removeID: AccessibilityID.Settings.Vocabulary.replacementRemove,
                    onRemove: replacements.remove(at:))
                    .accessibilityIdentifier(AccessibilityID.Settings.Vocabulary.replacementsList)
                if let error = replacements.error {
                    IssueText(error)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            dictionary.reload()
            replacements.reload()
        }
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
        // reload on any external write so the list reflects the just-added word without waiting for a
        // pane revisit or an in-pane mutation. Skip the reentrant reload our own writes fire.
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

    // All writes go through ConfigRepository, which read-modify-writes from disk (not from `@Published words`)
    // and invalidates the ConfigCache. The global Add-to-Vocabulary hotkey writes through the same repository
    // while this pane is open, so mutating stale in-memory state would silently drop that just-added word.
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
        // pane revisit or an in-pane mutation. Skip the reentrant reload our own writes fire.
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

    // All writes go through ConfigRepository (see DictionarySettingsModel.mutate). A `remove(at:)`
    // resolves the displayed row to a rule value first, then removes the matching rule from the
    // freshly-read set, so a rule the global hotkey appended concurrently is preserved.
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
