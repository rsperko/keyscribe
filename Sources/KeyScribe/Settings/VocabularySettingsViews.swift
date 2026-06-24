import SwiftUI
import KeyScribeKit

// Shared add/remove editors used identically by the global Vocabulary pane and a mode's own
// vocabulary. Both are designed to sit inside a Form Section.
struct DictionaryRows: View {
    let words: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    var placeholder = "Add a word, e.g. Kubernetes"
    @State private var newWord = ""

    var body: some View {
        ForEach(words, id: \.self) { word in
            HStack {
                Text(word)
                Spacer()
                RemoveButton { onRemove(word) }
            }
        }
        HStack {
            TextField(placeholder, text: $newWord)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Button("Add", action: commit).disabled(trimmed.isEmpty)
        }
    }

    private var trimmed: String { newWord.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        newWord = ""
    }
}

struct ReplacementRows: View {
    let rules: [ReplacementsSet.Rule]
    let onAdd: (String, String, Bool) -> Void
    let onRemove: (Int) -> Void
    @State private var heard = ""
    @State private var replace = ""
    @State private var regex = false
    @State private var advancedExpanded = false
    @State private var sample = ""

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
            }
        }
        HStack {
            TextField("Heard", text: $heard)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("Use instead", text: $replace)
                .textFieldStyle(.roundedBorder)
            Button("Add", action: commit).disabled(heardTrimmed.isEmpty)
        }
        DisclosureSection("Advanced replacements", isExpanded: $advancedExpanded) {
            Toggle("Match with a regular expression", isOn: $regex).toggleStyle(.checkbox)
            if regex {
                Text("Heard is treated as a pattern and Use instead as a template ($1 inserts the first capture group). Matching is case-sensitive.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Try sample text", text: $sample)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(preview).foregroundStyle(.secondary).font(.callout)
                }
            } else {
                Text("A plain replacement swaps the exact heard phrase for your text, before any AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var heardTrimmed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Non-destructive preview of what the regex rule would do to the sample, without touching saved
    // rules. Invalid patterns say so rather than throwing.
    private var preview: String {
        guard !heardTrimmed.isEmpty, !sample.isEmpty else { return "—" }
        guard let regex = RegexCache.regex(heardTrimmed) else { return "Invalid pattern" }
        let range = NSRange(sample.startIndex..., in: sample)
        return regex.stringByReplacingMatches(in: sample, range: range, withTemplate: replace)
    }

    private func commit() {
        guard !heardTrimmed.isEmpty else { return }
        onAdd(heardTrimmed, replace, regex)
        heard = ""
        replace = ""
        regex = false
        sample = ""
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
            Section("Dictionary") {
                Text("Add names, product terms, and jargon that KeyScribe repeatedly gets wrong. Keep this list short: too many terms can reduce recognition accuracy.")
                    .font(.caption).foregroundStyle(.secondary)
                DictionaryRows(words: dictionary.words, onAdd: dictionary.add, onRemove: dictionary.remove)
                if dictionary.words.count >= Self.dictionaryAdviceThreshold {
                    Label("You have \(dictionary.words.count) entries. Large dictionaries can make recognition less accurate, not more. Remove words KeyScribe now gets right, or move always-misheard phrases to Replacements.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = dictionary.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Replacements") {
                Text("Replace a consistently misheard phrase with the text you want. Runs before any AI rewrite. Pattern matching is under Advanced Replacements.")
                    .font(.caption).foregroundStyle(.secondary)
                ReplacementRows(
                    rules: replacements.rules,
                    onAdd: { replacements.add(heard: $0, replace: $1, regex: $2) },
                    onRemove: replacements.remove(at:))
                if let error = replacements.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
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

    private let supportDir: URL

    init(supportDir: URL) {
        self.supportDir = supportDir
        reload()
    }

    func reload() {
        words = DictionaryStore.loadOrDefault(supportDir: supportDir).words
        error = nil
    }

    func add(_ word: String) {
        save(DictionarySet(words: words).adding(word: word))
    }

    func remove(_ word: String) {
        save(DictionarySet(words: words).removing(word: word))
    }

    private func save(_ set: DictionarySet) {
        do {
            try DictionaryStore.write(set, to: supportDir)
            words = set.words
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

    private let supportDir: URL

    init(supportDir: URL) {
        self.supportDir = supportDir
        reload()
    }

    func reload() {
        rules = ReplacementsStore.loadOrDefault(supportDir: supportDir).rules
        error = nil
    }

    func add(heard: String, replace: String, regex: Bool) {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var set = ReplacementsSet(rules: rules)
        if regex {
            set.rules.append(.init(heard: trimmed, replace: replace, regex: true))
        } else {
            set = set.addingLiteral(heard: trimmed, replace: replace)
        }
        rules = set.rules
        persist()
    }

    func remove(at index: Int) {
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        persist()
    }

    private func persist() {
        do {
            try ReplacementsStore.write(ReplacementsSet(rules: rules), to: supportDir)
            error = nil
        } catch {
            self.error = "Could not save replacements: \(error.localizedDescription)"
        }
    }
}
