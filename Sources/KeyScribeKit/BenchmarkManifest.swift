import Foundation

// Input for `KeyScribe --benchmark <dir>`: one entry per recording, decoded from the unified corpus
// manifest (`clips[]`, schemaVersion 1). `text` is the ground truth (what was spoken); `biasTerms`
// (from `checks.stt.biasTerms`) are the dictionary terms the clip exercises; `file` locates the wav
// in the manifest's dir (defaults to `<id>.wav`).
public struct BenchmarkEntry: Sendable, Equatable {
    public let id: String
    public let file: String
    public let text: String
    public let biasTerms: [String]

    public init(id: String, text: String, biasTerms: [String] = [], file: String? = nil) {
        self.id = id
        self.text = text
        self.biasTerms = biasTerms
        self.file = file ?? "\(id).wav"
    }
}

public struct BenchmarkManifest: Sendable, Equatable {
    public let entries: [BenchmarkEntry]

    public init(entries: [BenchmarkEntry]) {
        self.entries = entries
    }

    public static func load(from url: URL) throws -> BenchmarkManifest {
        let raw = try JSONDecoder().decode(RawManifest.self, from: Data(contentsOf: url))
        return BenchmarkManifest(entries: raw.clips.map {
            BenchmarkEntry(id: $0.id, text: $0.text,
                           biasTerms: $0.checks?.stt?.biasTerms ?? [], file: $0.file)
        })
    }

    private struct RawManifest: Decodable {
        let clips: [RawClip]
    }
    private struct RawClip: Decodable {
        let id: String
        let file: String?
        let text: String
        let checks: RawChecks?
        struct RawChecks: Decodable { let stt: RawSTT? }
        struct RawSTT: Decodable { let biasTerms: [String]? }
    }
}
