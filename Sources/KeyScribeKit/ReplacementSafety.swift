import Foundation

// Static guard against catastrophic-backtracking ("evil") user regexes on the hot path. A pattern like
// `(a+)+$` can hang `NSRegularExpression` for seconds with no way to interrupt a synchronous match, so the
// only safe defence is to refuse it before it runs. Flags the dominant failure mode — a repetition
// quantifier applied to a group whose body is itself ambiguous: it either repeats (`*`/`+`/`{n≥2}`) or is
// nullable (`?`/`{0,…}`). A nullable body under a counted outer quantifier (`(a?){25}`) is the same
// combinatorial explosion as `(a+)+`. A repeated group whose body is a top-level alternation is the other
// half: `(a|aa)+` explodes because "aa" has two parses. Prefix-free literal branches are a prefix code and
// so uniquely decodable — `(cat|dog)+` cannot backtrack — which is the one alternation shape proven safe
// here. Comparison folds case because replacements compile `.caseInsensitive`, making `(ab|AB)+` the same
// branch twice. Conservative: never rejects a non/singly-quantified pattern, and over-rejects benign shapes
// like `(https?)+` and `(foo|foobar)+` (safe, but not provably so by this rule).
public enum ReplacementSafety {
    // Fail closed past the bound the editor enforces. Config files are hand-editable, so without this the
    // analysis below is the only thing between a pasted 100 KB pattern and the main actor.
    static let maxPatternLength = UserInputValidation.regexLimit

    public static func isSafe(_ pattern: String) -> Bool {
        guard pattern.count <= maxPatternLength else { return false }
        let chars = Array(pattern)
        var groupIsAmbiguous: [Bool] = []
        var groupHasAlternation: [Bool] = []
        var groupBodyStart: [Int] = []
        var poppedHadRepeat = false
        var lastWasGroupClose = false
        var lastWasGroupOpen = false
        var i = 0

        func markEnclosingGroupRepeats() {
            if !groupIsAmbiguous.isEmpty { groupIsAmbiguous[groupIsAmbiguous.count - 1] = true }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\" { i += 2; lastWasGroupClose = false; lastWasGroupOpen = false; continue }

            if c == "[" {
                i += 1
                if i < chars.count && chars[i] == "]" { i += 1 }   // literal ] as first member
                while i < chars.count && chars[i] != "]" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                lastWasGroupClose = false
                lastWasGroupOpen = false
                continue
            }

            if c == "(" {
                groupIsAmbiguous.append(false)
                groupHasAlternation.append(false)
                groupBodyStart.append(i + 1)
                lastWasGroupClose = false
                lastWasGroupOpen = true
                i += 1
                continue
            }

            if c == ")" {
                var ambiguous = groupIsAmbiguous.popLast() ?? false
                let hadAlternation = groupHasAlternation.popLast() ?? false
                let bodyStart = groupBodyStart.popLast() ?? i
                // Alternation is recorded DURING the pass; re-scanning each body at its closing paren made
                // this quadratic in nesting depth (measured 1.2 s on a 16 k-character pattern).
                if !ambiguous, hadAlternation, let branches = topLevelBranches(chars, from: bodyStart, to: i) {
                    ambiguous = !alternationIsProvablySafe(branches)
                }
                poppedHadRepeat = ambiguous
                if poppedHadRepeat { markEnclosingGroupRepeats() }
                lastWasGroupClose = true
                lastWasGroupOpen = false
                i += 1
                continue
            }

            if c == "|" {
                if !groupHasAlternation.isEmpty { groupHasAlternation[groupHasAlternation.count - 1] = true }
                lastWasGroupClose = false
                lastWasGroupOpen = false
                i += 1
                continue
            }

            if c == "*" || c == "+" {
                if lastWasGroupClose && poppedHadRepeat { return false }
                markEnclosingGroupRepeats()
                lastWasGroupClose = false
                lastWasGroupOpen = false
                i += 1
                continue
            }

            // `?` after `(` is group syntax (`(?:`/`(?i)`/`(?=`), not a quantifier. Elsewhere it makes the
            // preceding atom nullable → mark the enclosing group (but `?` alone never triggers a reject).
            if c == "?" {
                if !lastWasGroupOpen { markEnclosingGroupRepeats() }
                lastWasGroupClose = false
                lastWasGroupOpen = false
                i += 1
                continue
            }

            if c == "{" {
                if let (end, allowsRepetition, isNullable) = parseBrace(chars, from: i) {
                    if allowsRepetition && lastWasGroupClose && poppedHadRepeat { return false }
                    if allowsRepetition || isNullable { markEnclosingGroupRepeats() }
                    i = end + 1
                    lastWasGroupClose = false
                    lastWasGroupOpen = false
                    continue
                }
            }

            lastWasGroupClose = false
            lastWasGroupOpen = false
            i += 1
        }
        return true
    }

    // Splits a group body into its top-level `|` branches. Only a `|` at this group's own nesting level
    // separates branches: an escaped `\|`, a `|` inside a `[...]` class, and anything inside a nested group
    // are all literal here. nil when the body carries no top-level alternation, so an ordinary group is
    // never put through the alternation rule. A leading `?:` is dropped so a non-capturing group is judged
    // on its branches; other `(?…)` forms keep their prefix and fail the literal test below.
    private static func topLevelBranches(_ chars: [Character], from: Int, to end: Int) -> [String]? {
        var start = from
        if end - start >= 2, chars[start] == "?", chars[start + 1] == ":" { start += 2 }
        var branches: [String] = []
        var current = ""
        var depth = 0
        var j = start
        while j < end {
            let c = chars[j]
            if c == "\\" {
                current.append(c)
                if j + 1 < end { current.append(chars[j + 1]) }
                j += 2
                continue
            }
            if c == "[" {
                while j < end && chars[j] != "]" {
                    if chars[j] == "\\" { current.append(chars[j]); j += 1 }
                    if j < end { current.append(chars[j]); j += 1 }
                }
                if j < end { current.append(chars[j]); j += 1 }
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if c == "|" && depth == 0 {
                branches.append(current)
                current = ""
                j += 1
                continue
            }
            current.append(c)
            j += 1
        }
        guard !branches.isEmpty else { return nil }
        branches.append(current)
        return branches
    }

    // A repeated alternation is safe only when its branches form a prefix code: every branch a plain
    // literal, none a prefix of another. That makes the alternation uniquely decodable, so the matcher
    // never has two parses of the same input to backtrack between. Folding case is load-bearing, not
    // defensive — replacement patterns compile `.caseInsensitive`, so `ab` and `AB` are one branch.
    private static func alternationIsProvablySafe(_ branches: [String]) -> Bool {
        // Full case folding, not `lowercased()`: ICU's case-insensitive matching equates ß with SS, ſ with
        // s, and ﬃ with ffi, none of which lowercasing collapses — so `(ß|SS)+` reads as prefix-free while
        // backtracking exponentially. `locale: nil` keeps the verdict independent of the user's locale.
        let folded = branches.map(caseFolded)
        guard folded.allSatisfy({ !$0.isEmpty && $0.allSatisfy { !isMetacharacter($0) } }) else { return false }
        // Sorted order puts any prefix immediately before the string it prefixes, so adjacent pairs
        // suffice — no pairwise scan.
        let sorted = folded.sorted()
        for i in sorted.indices.dropLast() where sorted[i + 1].hasPrefix(sorted[i]) { return false }
        return true
    }

    // ICU's full folding is a Foundation bridge and measurably dominates this check, while every branch
    // that reaches it is almost always plain ASCII — where lowercasing IS the fold. Non-ASCII takes the
    // real path, which is what ß/ſ/ﬃ need.
    private static func caseFolded(_ branch: String) -> String {
        branch.allSatisfy(\.isASCII)
            ? branch.lowercased()
            : branch.folding(options: [.caseInsensitive], locale: nil)
    }

    private static let metacharacters: Set<Character> = ["\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"]

    private static func isMetacharacter(_ c: Character) -> Bool { metacharacters.contains(c) }

    // Parses a `{...}` quantifier from `from`. Returns the closing brace index, whether it permits ≥2
    // repetitions (`{n,}`, `{n,m}` m≥2, `{n}` n≥2), and whether it is nullable (`{0,…}` / `{0}`). Either
    // property makes a group body ambiguous — `(a+){2,999}` explodes on the repeat, `(a?){25}` on the
    // nullable — so both feed the same `(a+)+` danger check. `{1}`/`{1,1}` permit exactly one and are safe.
    // nil if `{` is not a valid quantifier (literal brace).
    private static func parseBrace(_ chars: [Character], from: Int) -> (end: Int, allowsRepetition: Bool, isNullable: Bool)? {
        var j = from + 1
        var body = ""
        while j < chars.count && chars[j] != "}" { body.append(chars[j]); j += 1 }
        guard j < chars.count else { return nil }
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 2,
              parts.allSatisfy({ $0.isEmpty || $0.allSatisfy(\.isNumber) }),
              !(parts[0].isEmpty && parts.count == 1) else { return nil }
        let allowsRepetition: Bool
        if parts.count == 2 {
            if parts[1].isEmpty { allowsRepetition = true }                    // {n,}
            else { allowsRepetition = (Int(parts[1]) ?? 0) >= 2 }              // {n,m}
        } else {
            allowsRepetition = (Int(parts[0]) ?? 0) >= 2                       // {n}
        }
        let isNullable = (parts[0].isEmpty || (Int(parts[0]) ?? 0) == 0)       // {0,…} / {0}
        return (j, allowsRepetition, isNullable)
    }
}
