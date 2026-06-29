import SwiftUI
import KeyScribeKit

struct DictionaryRows: View {
    let words: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ForEach(words, id: \.self) { word in
            HStack {
                Text(word)
                Spacer()
                RemoveButton { onRemove(word) }
            }
        }
    }
}

struct ReplacementRows: View {
    let rules: [ReplacementsSet.Rule]
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
    @FocusState private var focus: Field?

    private enum Field { case heard, replace }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(regex ? "Heard pattern" : "Word or heard phrase")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(regex ? "Regular expression" : "Add a word or heard phrase", text: $heard)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .heard)
                    .onSubmit(commit)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(regex ? "Use instead" : "Use instead (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(regex ? "Replacement text" : "Optional correction", text: $replace)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .replace)
                    .onSubmit(commit)
                    .frame(maxWidth: .infinity)
            }
            Toggle("Match heard phrase as a regular expression", isOn: $regex)
                .toggleStyle(.checkbox)
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if regexInvalid {
                Label("That is not a valid regular expression.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Add", action: commit)
                    .disabled(!canAdd)
            }
        }
        .onAppear { focus = .heard }
    }

    private var heardTrimmed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var replaceTrimmed: String { replace.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var regexInvalid: Bool {
        regex && !heardTrimmed.isEmpty && RegexCache.regex(heardTrimmed) == nil
    }
    private var canAdd: Bool { !heardTrimmed.isEmpty && (!regex || !replaceTrimmed.isEmpty) && !regexInvalid }

    private var helpText: String {
        if regex {
            return "Regex always creates a replacement, so Use instead is required. Use captures like $1."
        }
        return "Leave Use instead empty to add a word. Fill it in to create an automatic replacement."
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
                Text("Names, product terms, and jargon \(Branding.appName) should recognize as written. Keep this list short; too many terms can reduce recognition accuracy.")
                    .font(.caption).foregroundStyle(.secondary)
                DictionaryRows(words: dictionary.words, onRemove: dictionary.remove)
                if dictionary.words.count >= Self.dictionaryAdviceThreshold {
                    Label("You have \(dictionary.words.count) entries. Large dictionaries can make recognition less accurate, not more. Remove words \(Branding.appName) now gets right, or move always-misheard phrases to Replacements.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = dictionary.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Automatic Replacements") {
                Text("Changes a consistently misheard phrase to the text you want. Replacements run before any AI rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
                ReplacementRows(
                    rules: replacements.rules,
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
