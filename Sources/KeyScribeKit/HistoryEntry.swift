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
    // Human-readable name of the input device this dictation actually recorded from (the truly-bound
    // device, not the preferred selection — a disconnected preferred mic falls back to the default here).
    // Recorded so a "my transcripts got worse" report can be traced to the mic. nil on older entries.
    public var device: String?
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
    // The provider's raw reply, verbatim (pre-enforcement, carrying tokens like `prompt` does) — the
    // "Show exactly what was received" mirror of `prompt`. On a localFallback entry it is the rejected
    // reply that explains `fallbackReason`. nil on local-only and older entries, and when the call failed.
    public var received: String?
    // How this mode was chosen (UX2 phase 7c) — additive optional fields, nil on older rows.
    public var modeChoice: ModeChoiceReason?
    public var routedPhrase: String?
    // Display string of the shortcut that started this dictation, when the mode was chosen by its trigger
    // key (modeChoice == .triggerKey). Lets History show "Started by its shortcut (Right-⌥)". nil otherwise.
    public var triggerKey: String?
    // Why a `localFallback` entry kept the local text (an HTTP error, missing key, or validation failure).
    // Provider error text or a fixed local string, never user content. nil on non-fallback and older rows.
    public var fallbackReason: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case modeName = "mode"
        case engine
        case device
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
        case received
        case modeChoice = "mode_choice"
        case routedPhrase = "routed_phrase"
        case triggerKey = "trigger_key"
        case fallbackReason = "fallback_reason"
    }

    public init(
        timestamp: Date, modeName: String, engine: String? = nil, device: String? = nil,
        heard: String, transformed: String? = nil,
        result: String, outcome: Outcome,
        cloudInvolved: Bool, redaction: Bool, contextCategories: [String],
        connection: String? = nil, model: String? = nil, prompt: String? = nil, received: String? = nil,
        modeChoice: ModeChoiceReason? = nil, routedPhrase: String? = nil,
        triggerKey: String? = nil, fallbackReason: String? = nil
    ) {
        self.timestamp = timestamp
        self.modeName = modeName
        self.engine = engine
        self.device = device
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
        self.received = received
        self.modeChoice = modeChoice
        self.routedPhrase = routedPhrase
        self.triggerKey = triggerKey
        self.fallbackReason = fallbackReason
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
