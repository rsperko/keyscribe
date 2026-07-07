import Foundation

// Expands `\n`/`\t`/`\r` in a regex rule's replacement before it reaches NSRegularExpression, whose own
// template escapes (`\$`, `$1`) do not turn `\n` into a newline. `\\` passes through as a pair so it stays a
// literal backslash for the template engine and its inner `\` can't form a spurious `\n`.
public enum ReplacementEscapes {
    public static func expandTemplate(_ template: String) -> String {
        guard template.contains("\\") else { return template }
        let chars = Array(template)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else {
                out.append(chars[i])
                i += 1
                continue
            }
            switch chars[i + 1] {
            case "n": out.append("\n"); i += 2
            case "t": out.append("\t"); i += 2
            case "r": out.append("\r"); i += 2
            case "\\": out.append("\\"); out.append("\\"); i += 2
            default: out.append("\\"); i += 1
            }
        }
        return out
    }
}
