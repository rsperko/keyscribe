import Foundation

// Pass/fail criterion for the post-install model smoke test: transcribe a known clip and confirm enough
// distinctive words came back. Deliberately loose (engines/quantizations word things differently) — it
// verifies "the model basically works," not accuracy. Audio + transcription are the OS edge; this is pure.
public enum ModelSelfTest {
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    public static func passes(transcript: String, expectedWords: [String], minMatches: Int) -> Bool {
        let words = Set(normalize(transcript).split(separator: " ").map(String.init))
        let matched = expectedWords.reduce(into: 0) { count, word in
            if words.contains(normalize(word)) { count += 1 }
        }
        return matched >= minMatches
    }
}
