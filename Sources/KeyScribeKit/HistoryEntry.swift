import Foundation

// One local-history record (design.md §4.7): raw transcription, mode, the exact LLM prompt (carrying the
// ⟦SN:…⟧ tokens, never their originals), the final inserted text, and data-boundary metadata. Audio and the
// redaction map are NEVER stored. The transcription/result still contain real values, so the privacy lever
// is per-mode `exclude_from_history`.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case inserted
        case copied
        case localFallback = "local_fallback"
        case failed
    }

    public var timestamp: Date
    public var modeName: String
    // Display name of the STT engine that produced `heard`. nil on older entries (detail shows "On-device").
    public var engine: String?
    public var heard: String
    // Local text after replacements and spoken edits, before any AI rewrite — the middle of Heard →
    // Transformed → Result (ui_design.md §8). Recorded on every entry (equals Heard when nothing changed)
    // as durable proof the local pipeline ran. nil only on older entries.
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
        case engine
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
        timestamp: Date, modeName: String, engine: String? = nil, heard: String, transformed: String? = nil,
        result: String, outcome: Outcome,
        cloudInvolved: Bool, redaction: Bool, contextCategories: [String],
        connection: String? = nil, model: String? = nil, prompt: String? = nil
    ) {
        self.timestamp = timestamp
        self.modeName = modeName
        self.engine = engine
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

    // One JSONL line. JSON escapes embedded newlines, so a multi-line transcript stays on one line —
    // load-bearing for the one-entry-per-line format.
    public func jsonLine() throws -> String {
        String(decoding: try Self.encoder.encode(self), as: UTF8.self)
    }

    public init(jsonLine: String) throws {
        self = try Self.decoder.decode(HistoryEntry.self, from: Data(jsonLine.utf8))
    }

    public static func contextLabel(for category: String) -> String? {
        switch category {
        case "app": "App shared"
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
