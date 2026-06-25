import Foundation

// One local-history record (design.md §4.7). Stores the raw transcription, the mode, the exact
// prompt sent to the LLM (carrying the ⟦SN:…⟧ tokens, never their originals), and the final
// inserted text — plus the data-boundary metadata the History detail view shows. **Audio is never
// stored and the redaction map is never stored.** The raw transcription and result still contain
// real values, so the privacy lever for sensitive work is per-mode `exclude_from_history`.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case inserted
        case copied
        case localFallback = "local_fallback"
        case failed
    }

    public var timestamp: Date
    public var modeName: String
    public var heard: String
    // The local text after replacements and spoken edits, before any AI rewrite — the middle of the
    // Heard → Transformed → Result model (ui_design.md §8). nil when nothing local changed the
    // transcript (older entries also decode to nil), in which case Heard already equals Result.
    public var transformed: String?
    public var result: String
    public var outcome: Outcome
    public var cloudInvolved: Bool
    public var redaction: Bool
    public var contextCategories: [String]
    public var connection: String?
    public var model: String?
    public var prompt: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case modeName = "mode"
        case heard
        case transformed
        case result
        case outcome
        case cloudInvolved = "cloud_involved"
        case redaction
        case contextCategories = "context_categories"
        case connection
        case model
        case prompt
    }

    public init(
        timestamp: Date, modeName: String, heard: String, transformed: String? = nil,
        result: String, outcome: Outcome,
        cloudInvolved: Bool, redaction: Bool, contextCategories: [String],
        connection: String? = nil, model: String? = nil, prompt: String? = nil
    ) {
        self.timestamp = timestamp
        self.modeName = modeName
        self.heard = heard
        self.transformed = transformed
        self.result = result
        self.outcome = outcome
        self.cloudInvolved = cloudInvolved
        self.redaction = redaction
        self.contextCategories = contextCategories
        self.connection = connection
        self.model = model
        self.prompt = prompt
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // One JSONL line. JSON escapes embedded newlines, so a multi-line transcript stays on a single
    // line — load-bearing for the one-entry-per-line file format.
    public func jsonLine() throws -> String {
        String(decoding: try Self.encoder.encode(self), as: UTF8.self)
    }

    public init(jsonLine: String) throws {
        self = try Self.decoder.decode(HistoryEntry.self, from: Data(jsonLine.utf8))
    }

    public static func contextLabel(for category: String) -> String? {
        switch category {
        case "app": "App shared"
        case "visible text": "Visible text shared"
        case "preceding text": "Preceding text shared"
        default: nil
        }
    }

    public var contextLabels: [String] { contextCategories.compactMap(Self.contextLabel) }

    public var dataBoundaryLabels: [String] {
        if !cloudInvolved { return ["On this Mac"] }
        var labels = ["Cloud rewrite"]
        if redaction { labels.append("Best-effort redaction") }
        labels.append(contentsOf: contextLabels)
        return labels
    }
}
