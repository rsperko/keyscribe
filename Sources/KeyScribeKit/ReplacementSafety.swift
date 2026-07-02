import Foundation

// Static guard against catastrophic-backtracking ("evil") user regexes on the dictation hot path.
// A valid-but-pathological pattern like `(a+)+$` can hang `NSRegularExpression` for seconds on a
// modest input, and there is no way to interrupt a synchronous match — so the only safe defence is
// to refuse the pattern before it ever runs. We flag the dominant failure mode: a repetition
// quantifier applied to a group whose body itself contains a repetition (nested quantifiers). This
// is conservative — it never rejects a non-quantified or singly-quantified pattern — and misses
// alternation-overlap evils like `(a|a)*`, which are far rarer in practice.
public enum ReplacementSafety {
    public static func isSafe(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var stack: [Bool] = []          // per open group: does its body contain a repetition?
        var poppedHadRepeat = false     // did the group that just closed contain a repetition?
        var lastWasGroupClose = false
        var i = 0

        func markEnclosingGroupRepeats() {
            if !stack.isEmpty { stack[stack.count - 1] = true }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\" { i += 2; lastWasGroupClose = false; continue }

            if c == "[" {
                i += 1
                if i < chars.count && chars[i] == "]" { i += 1 }   // literal ] as first member
                while i < chars.count && chars[i] != "]" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                lastWasGroupClose = false
                continue
            }

            if c == "(" { stack.append(false); lastWasGroupClose = false; i += 1; continue }

            if c == ")" {
                poppedHadRepeat = stack.popLast() ?? false
                if poppedHadRepeat { markEnclosingGroupRepeats() }
                lastWasGroupClose = true
                i += 1
                continue
            }

            if c == "*" || c == "+" {
                if lastWasGroupClose && poppedHadRepeat { return false }
                markEnclosingGroupRepeats()
                lastWasGroupClose = false
                i += 1
                continue
            }

            if c == "{" {
                if let (end, allowsRepetition) = parseBrace(chars, from: i) {
                    if allowsRepetition {
                        if lastWasGroupClose && poppedHadRepeat { return false }
                        markEnclosingGroupRepeats()
                    }
                    i = end + 1
                    lastWasGroupClose = false
                    continue
                }
            }

            lastWasGroupClose = false
            i += 1
        }
        return true
    }

    // Parses a `{...}` quantifier starting at `from`. Returns the index of the closing brace and
    // whether it permits two or more repetitions (`{n,}`, `{n,m}` with m≥2, or exact `{n}` with
    // n≥2) — any such quantifier applied to a group whose body already contains a repetition is
    // the same combinatorial-split danger as `(a+)+`, regardless of how tight the bound is (e.g.
    // `(a+){2,999}`). `{0,1}`/`{1,1}`/`{0}`/`{1}` permit at most one repetition and are safe.
    // Returns nil if `{` is not a valid quantifier (then it is a literal brace).
    private static func parseBrace(_ chars: [Character], from: Int) -> (end: Int, allowsRepetition: Bool)? {
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
        return (j, allowsRepetition)
    }
}
