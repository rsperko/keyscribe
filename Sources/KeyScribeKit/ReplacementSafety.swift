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
                if let (end, unbounded) = parseBrace(chars, from: i) {
                    if unbounded {
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
    // whether it is "unbounded enough" to drive backtracking: `{n,}` (no upper bound) or a very
    // large upper bound. Bounded small repeats like `{2,4}` are safe. Returns nil if `{` is not a
    // valid quantifier (then it is a literal brace).
    private static func parseBrace(_ chars: [Character], from: Int) -> (end: Int, unbounded: Bool)? {
        var j = from + 1
        var body = ""
        while j < chars.count && chars[j] != "}" { body.append(chars[j]); j += 1 }
        guard j < chars.count else { return nil }
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 2,
              parts.allSatisfy({ $0.isEmpty || $0.allSatisfy(\.isNumber) }),
              !(parts[0].isEmpty && parts.count == 1) else { return nil }
        let unbounded: Bool
        if parts.count == 2 {
            if parts[1].isEmpty { unbounded = true }                       // {n,}
            else { unbounded = (Int(parts[1]) ?? 0) > 1000 }               // {n,m} with large m
        } else {
            unbounded = false                                              // {n}
        }
        return (j, unbounded)
    }
}
