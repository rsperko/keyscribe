import Foundation

// Static guard against catastrophic-backtracking ("evil") user regexes on the hot path. A pattern like
// `(a+)+$` can hang `NSRegularExpression` for seconds with no way to interrupt a synchronous match, so the
// only safe defence is to refuse it before it runs. Flags the dominant failure mode — a repetition
// quantifier applied to a group whose body is itself ambiguous: it either repeats (`*`/`+`/`{n≥2}`) or is
// nullable (`?`/`{0,…}`). A nullable body under a counted outer quantifier (`(a?){25}`) is the same
// combinatorial explosion as `(a+)+`. Conservative: never rejects a non/singly-quantified pattern, over-
// rejects benign shapes like `(https?)+`, and misses rarer alternation-overlap evils like `(a|a)*`.
public enum ReplacementSafety {
    public static func isSafe(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var stack: [Bool] = []          // per open group: is its body ambiguous (repeats or nullable)?
        var poppedHadRepeat = false     // was the group that just closed ambiguous?
        var lastWasGroupClose = false
        var lastWasGroupOpen = false
        var i = 0

        func markEnclosingGroupRepeats() {
            if !stack.isEmpty { stack[stack.count - 1] = true }
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

            if c == "(" { stack.append(false); lastWasGroupClose = false; lastWasGroupOpen = true; i += 1; continue }

            if c == ")" {
                poppedHadRepeat = stack.popLast() ?? false
                if poppedHadRepeat { markEnclosingGroupRepeats() }
                lastWasGroupClose = true
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
