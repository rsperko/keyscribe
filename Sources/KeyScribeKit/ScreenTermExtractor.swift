import Foundation

// Harvests technical identifiers (camelCase, snake_case, letter+digit mixes, dotted-name components)
// from captured on-screen text, as ephemeral per-dictation terms for exact-normalized dictionary
// recovery. Prose — lowercase, Capitalized, or ALLCAPS words with no structural marker — is never a
// term: a harvested term can only re-case/re-space something the user already said, so admitting
// ordinary words would buy nothing and grow the collision surface. Curated dictionary terms always
// win: any harvest whose normalized form collides with one is dropped here.
public enum ScreenTermExtractor {
    public static func terms(in text: String, excluding: [String], limit: Int = 32) -> [String] {
        var claimed = Set(excluding.map(normalize))
        var result: [String] = []
        outer: for raw in text.split(whereSeparator: { !isAlphanumeric($0) && $0 != "_" && $0 != "." }) {
            for component in raw.split(separator: ".").map(String.init) {
                guard isIdentifier(component) else { continue }
                let norm = normalize(component)
                guard norm.count >= 4, claimed.insert(norm).inserted else { continue }
                result.append(component)
                if result.count == limit { break outer }
            }
        }
        return result
    }

    private static func isIdentifier(_ s: String) -> Bool {
        if s.contains("_") { return s.contains(where: isAlphanumeric) }
        if s.contains(where: \.isNumber), s.contains(where: { $0.isLetter }) { return true }
        return hasInteriorCaseBoundary(s)
    }

    // "useState"/"CaptureWriter" have a lower→upper transition; "HTTPClient" has an upper-run→lower
    // boundary. A bare initial capital ("Capture") is prose, not an identifier.
    private static func hasInteriorCaseBoundary(_ s: String) -> Bool {
        let chars = Array(s)
        for i in 0..<max(0, chars.count - 1) {
            if chars[i].isLowercase, chars[i + 1].isUppercase { return true }
            if i + 2 < chars.count, chars[i].isUppercase, chars[i + 1].isUppercase,
               chars[i + 2].isLowercase { return true }
        }
        return false
    }

    private static func isAlphanumeric(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
