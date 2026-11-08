import Foundation
import KeyScribeKit

enum VocabularyScopeDestination: Hashable {
    case global
    case mode(String)
    case shared(String)
}

struct VocabularyScopeSections {
    let enabled: [Mode]
    let disabled: [Mode]
}

enum VocabularyScopePicker {
    static func sections(for modes: [Mode]) -> VocabularyScopeSections {
        let editable = modes.filter(\.hasOwnVocabulary)
        return VocabularyScopeSections(
            enabled: editable.filter(\.enabled),
            disabled: editable.filter { !$0.enabled })
    }

    static func resolved(
        _ selection: VocabularyScopeDestination, in modes: [Mode], shared: [SharedVocabulary] = []
    ) -> VocabularyScopeDestination {
        switch selection {
        case .global: return selection
        case .mode(let id): return modes.contains { $0.id == id && $0.hasOwnVocabulary } ? selection : .global
        case .shared(let id): return shared.contains { $0.id == id } ? selection : .global
        }
    }

    static func sharedSummary(_ vocabulary: SharedVocabulary) -> String {
        globalSummary(words: vocabulary.words, rules: vocabulary.rules)
    }

    // Who a shared vocabulary reaches, said before what it holds.
    static func usedBy(_ id: String, in modes: [Mode]) -> [Mode] {
        modes.filter { $0.hasOwnVocabulary && $0.sharedVocabularies.contains(id) }
    }

    // Membership is not the same as use: a disabled mode is named as such, and the effect says when it applies.
    static func audience(_ users: [Mode]) -> (names: String, effect: String) {
        guard !users.isEmpty else { return ("Not used by any modes.", "Choose modes below to start using it.") }
        let names = ListFormatter.localizedString(byJoining: users.map { $0.enabled ? $0.name : "\($0.name) (disabled)" })
        let enabled = users.filter(\.enabled)
        let disabled = users.filter { !$0.enabled }
        if enabled.isEmpty {
            return (names, disabled.count == 1 ? "Used when this mode is enabled." : "Used when these modes are enabled.")
        }
        if !disabled.isEmpty {
            let now = ListFormatter.localizedString(byJoining: enabled.map(\.name))
            let later = ListFormatter.localizedString(byJoining: disabled.map(\.name))
            return (names, "Changes here apply to \(now) now, and to \(later) when \(disabled.count == 1 ? "it is" : "they are") enabled.")
        }
        return (names, users.count == 1 ? "Changes here apply to that mode." : users.count == 2
            ? "Changes here apply to both modes." : "Changes here apply to all \(users.count) modes.")
    }

    // In the list, a vocabulary no enabled mode uses says so, so saved entries are not mistaken for active ones.
    static func sharedListSubtitle(_ vocabulary: SharedVocabulary, users: [Mode]) -> String {
        if users.isEmpty { return "Not used by any modes" }
        if !users.contains(where: \.enabled) { return "Used only by disabled modes" }
        return sharedSummary(vocabulary)
    }

    // Said before detaching: entries a mode keeps of its own, including choices that settled a disagreement, go on
    // working, so a correction that still applies does not look like a failed removal.
    static func detachNote(modes: [String], vocabularies: [String]) -> String? {
        guard !modes.isEmpty, !vocabularies.isEmpty else { return nil }
        return "\(ListFormatter.localizedString(byJoining: modes)) will stop using "
            + "\(ListFormatter.localizedString(byJoining: vocabularies)). Global and mode-only entries will still apply."
    }

    // A mode's own line: what it uses, then where its own entries apply.
    static func modeUses(_ mode: Mode, shared: [SharedVocabulary]) -> String {
        let names = (mode.dictionary.includeGlobal || mode.replacements.includeGlobal ? ["Global"] : [])
            + VocabularyMerge.using(mode, shared).map(\.name)
        let uses = names.isEmpty ? "Uses only its own vocabulary." : "Uses \(ListFormatter.localizedString(byJoining: names))."
        return "\(uses) Entries added below apply only to \(mode.name)."
    }

    static func summary(for mode: Mode) -> String {
        let wordCount = mode.dictionary.words.count
        let replacementCount = mode.replacements.rules.count
        var parts: [String] = []
        if wordCount > 0 { parts.append("\(wordCount) word\(wordCount == 1 ? "" : "s")") }
        if replacementCount > 0 { parts.append("\(replacementCount) replacement\(replacementCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "No mode-only vocabulary" : parts.joined(separator: " · ")
    }

    static func globalSummary(words: [String], rules: [ReplacementsSet.Rule]) -> String {
        let wordCount = words.count
        let replacementCount = rules.count
        var parts: [String] = []
        if wordCount > 0 { parts.append("\(wordCount) word\(wordCount == 1 ? "" : "s")") }
        if replacementCount > 0 { parts.append("\(replacementCount) replacement\(replacementCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "No vocabulary yet" : parts.joined(separator: " · ")
    }
}

enum VocabularyEditAnalysis {
    static func scope(
        for scope: VocabularyScope, excluding original: ReplacementsSet.Rule
    ) -> VocabularyScope {
        var analysisScope = scope
        if analysisScope.local != nil {
            if let index = analysisScope.local?.rules.firstIndex(of: original) {
                analysisScope.local?.rules.remove(at: index)
            }
        } else if let index = analysisScope.globalRules.firstIndex(of: original) {
            analysisScope.globalRules.remove(at: index)
        }
        return analysisScope
    }
}
