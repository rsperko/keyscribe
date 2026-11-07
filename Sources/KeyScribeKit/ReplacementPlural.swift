import Foundation

// The plural rule the composer offers to add beside a one-word rule ("pain" → "pane" offers "pains" → "panes").
// Only an offer, unchecked: grammar is not guessed for the user, and a saved rule stays exactly what it says.
// Only `+s` plurals of letters-only words, not for a rule that writes a name ("mark" → "Marc"), and not when a
// rule for that plural already exists.
public enum ReplacementPlural {
    public static func offer(for rule: ReplacementsSet.Rule, among existing: [ReplacementsSet.Rule]) -> ReplacementsSet.Rule? {
        guard !rule.regex, !rule.wholeDictation, isPlainWord(rule.heard), isPlainWord(rule.replace),
              rule.replace == rule.replace.lowercased(), rule.heard.lowercased() != rule.replace.lowercased()
        else { return nil }
        let plural = ReplacementsSet.Rule(heard: rule.heard + "s", replace: rule.replace + "s", regex: false)
        let taken = existing.contains { !$0.regex && $0.heard.caseInsensitiveCompare(plural.heard) == .orderedSame }
        return taken ? nil : plural
    }

    private static func isPlainWord(_ word: String) -> Bool {
        let lowered = word.lowercased()
        guard !lowered.isEmpty, lowered.allSatisfy(\.isLetter) else { return false }
        return !["s", "x", "z", "ch", "sh", "y"].contains { lowered.hasSuffix($0) }
    }
}
