import KeyScribeKit

enum VocabularyScopeDestination: Hashable {
    case global
    case mode(String)
}

struct VocabularyScopeSections {
    let enabled: [Mode]
    let disabled: [Mode]
}

enum VocabularyScopePicker {
    static func sections(for modes: [Mode]) -> VocabularyScopeSections {
        let editable = modes.filter { !$0.isSystem }
        return VocabularyScopeSections(
            enabled: editable.filter(\.enabled),
            disabled: editable.filter { !$0.enabled })
    }

    static func resolved(_ selection: VocabularyScopeDestination, in modes: [Mode]) -> VocabularyScopeDestination {
        guard case let .mode(id) = selection else { return selection }
        return modes.contains { $0.id == id && !$0.isSystem } ? selection : .global
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
