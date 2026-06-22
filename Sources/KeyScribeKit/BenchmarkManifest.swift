import Foundation

// Input for `KeyScribe --benchmark <dir>`: one entry per recording. `id` pairs with `<id>.wav` in the
// same dir; `text` is the ground truth (what you read aloud); `biasTerms` are the dictionary terms
// the clip is meant to exercise (empty for clips that just measure plain accuracy).
public struct BenchmarkEntry: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let biasTerms: [String]

    public init(id: String, text: String, biasTerms: [String] = []) {
        self.id = id
        self.text = text
        self.biasTerms = biasTerms
    }
}

public struct BenchmarkManifest: Codable, Sendable, Equatable {
    public let entries: [BenchmarkEntry]

    public init(entries: [BenchmarkEntry]) {
        self.entries = entries
    }

    public static func load(from url: URL) throws -> BenchmarkManifest {
        try JSONDecoder().decode(BenchmarkManifest.self, from: Data(contentsOf: url))
    }
}
