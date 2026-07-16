import Foundation

public enum ReplacementAuthoring {
    public static let maxCharacters = 65_536
    public static let previewLimit = 160

    public static func isWithinLimit(_ replacement: String) -> Bool {
        replacement.count <= maxCharacters
    }

    public static func normalizingLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func regexReturnMarkerValid(_ replacement: String) -> Bool {
        guard replacement.contains("<CR>") else { return true }
        return ReturnSuffix.parse(ReplacementEscapes.expandTemplate(replacement)) != nil
    }

    public struct Preview: Equatable, Sendable {
        public let text: String
        public let isTruncated: Bool
        public let fullCount: Int
    }

    public static func preview(for replacement: String) -> Preview {
        let fullCount = replacement.count
        guard fullCount > 0 else { return Preview(text: "Nothing", isTruncated: false, fullCount: 0) }
        let escaped = escapedPrefix(
            replacement, spacesVisible: replacement.allSatisfy(\.isWhitespace))
        guard escaped.count > previewLimit else {
            return Preview(text: escaped, isTruncated: false, fullCount: fullCount)
        }
        let truncated = String(escaped.prefix(previewLimit - 1)) + "…"
        return Preview(text: truncated, isTruncated: true, fullCount: fullCount)
    }

    private static func escapedPrefix(_ text: String, spacesVisible: Bool) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\r\n": out += #"\r\n"#
            case "\n": out += #"\n"#
            case "\r": out += #"\r"#
            case "\t": out += #"\t"#
            case " " where spacesVisible: out += "␣"
            default: out.append(character)
            }
            if out.count > previewLimit { break }
        }
        return out
    }
}
