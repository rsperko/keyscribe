import Foundation

public enum ReasoningPreference: Hashable, Sendable, Codable {
    case lowestAvailable
    case level(String)
    case modelDefault

    public static let levels = ["minimal", "low", "medium", "high", "xhigh", "max"]

    public init(storedValue: String) {
        let value = storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "", "lowest", "none", "off": self = .lowestAvailable
        case "model_default", "auto", "default": self = .modelDefault
        default: self = .level(value)
        }
    }

    public init?(legacyEffort: String?) {
        guard let raw = legacyEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        self.init(storedValue: raw)
    }

    public init?(legacyGeminiLevel: String?) {
        guard let raw = legacyGeminiLevel?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        self = raw.lowercased() == "minimal" ? .lowestAvailable : ReasoningPreference(storedValue: raw)
    }

    public var storedValue: String {
        switch self {
        case .lowestAvailable: "lowest"
        case .modelDefault: "model_default"
        case .level(let level): level
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(storedValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

public enum ReasoningRequest: Equatable, Sendable {
    case effort(String)
    case anthropicThinking(String)
    case anthropicEffort(String, adaptive: Bool)
    case geminiLevel(String)
    case geminiBudget(Int)

    public var disablesReasoning: Bool {
        switch self {
        case .effort(let value): value == "none"
        case .anthropicThinking(let type): type == "disabled"
        case .geminiBudget(let budget): budget == 0
        case .anthropicEffort, .geminiLevel: false
        }
    }

    public var levelName: String {
        switch self {
        case .effort(let value): value == "none" ? "off" : value
        case .anthropicThinking(let type): type == "disabled" ? "off" : "off before answering"
        case .anthropicEffort(let value, _): value
        case .geminiLevel(let value): value
        case .geminiBudget(let budget): budget == 0 ? "off" : "minimal"
        }
    }

    var effortRank: Int? {
        guard case .effort(let value) = self else { return nil }
        return ReasoningLadder.rank(value)
    }
}

public enum ReasoningShape: Equatable, Sendable {
    case rung(ReasoningRequest)
    case modelDefault(exhausted: Bool)
    case unknown

    public var request: ReasoningRequest? {
        if case .rung(let request) = self { return request }
        return nil
    }

    public var logDescription: String {
        switch self {
        case .rung(.effort(let value)): "effort:\(value)"
        case .rung(.anthropicThinking(let type)): "thinking:\(type)"
        case .rung(.anthropicEffort(let value, let adaptive)): adaptive ? "adaptive+effort:\(value)" : "effort:\(value)"
        case .rung(.geminiLevel(let value)): "thinkingLevel:\(value)"
        case .rung(.geminiBudget(let value)): "thinkingBudget:\(value)"
        case .modelDefault(let exhausted): exhausted ? "model-default(exhausted)" : "model-default"
        case .unknown: "unknown"
        }
    }
}

public enum ReasoningRejection: Equatable, Sendable {
    case unknownField
    case value(listed: [String])
}

public enum ReasoningStep: Equatable, Sendable {
    case to(ReasoningShape)
    case refuse(level: String)
}

public enum ReasoningLadder {
    static let vocabulary = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func rank(_ value: String) -> Int? {
        vocabulary.firstIndex(of: value.lowercased())
    }

    private static let geminiBudgetForLevel = ["minimal": 128, "low": 1024, "medium": 8192, "high": 24576]

    public static func rungs(for preference: ReasoningPreference, provider: Connection.Provider) -> [ReasoningRequest] {
        switch (preference, provider) {
        case (.modelDefault, _):
            return []
        case (.lowestAvailable, .openai), (.lowestAvailable, .openaiCompatible):
            return [.effort("none"), .effort("minimal"), .effort("low")]
        case (.lowestAvailable, .anthropic):
            return [.anthropicThinking("disabled"), .anthropicThinking("between_tools"), .anthropicEffort("low", adaptive: false)]
        case (.lowestAvailable, .gemini):
            return [.geminiLevel("minimal"), .geminiLevel("low"), .geminiBudget(0), .geminiBudget(128)]
        case (.level(let level), .openai), (.level(let level), .openaiCompatible):
            return [.effort(level)]
        case (.level(let level), .anthropic):
            return [.anthropicEffort(level, adaptive: true)]
        case (.level(let level), .gemini):
            return [.geminiLevel(level)] + (geminiBudgetForLevel[level].map { [.geminiBudget($0)] } ?? [])
        }
    }

    public static func initialShape(for preference: ReasoningPreference, provider: Connection.Provider) -> ReasoningShape {
        rungs(for: preference, provider: provider).first.map(ReasoningShape.rung) ?? .modelDefault(exhausted: false)
    }

    public static func step(
        from current: ReasoningShape, preference: ReasoningPreference, provider: Connection.Provider,
        rejection: ReasoningRejection
    ) -> ReasoningStep? {
        guard let sent = current.request else { return nil }
        let ladder = rungs(for: preference, provider: provider)
        let index = ladder.firstIndex(of: sent) ?? 0
        let remaining = Array(ladder.dropFirst(index + 1))

        if case .level(let level) = preference {
            if rejection == .unknownField, let translation = remaining.first { return .to(.rung(translation)) }
            return .refuse(level: level)
        }

        switch rejection {
        case .unknownField:
            if case .geminiLevel = sent,
               let budget = remaining.first(where: { if case .geminiBudget = $0 { true } else { false } }) {
                return .to(.rung(budget))
            }
            return .to(.unknown)
        case .value(let listed):
            if let currentRank = sent.effortRank {
                let candidates = listed.compactMap { value in rank(value).map { (value.lowercased(), $0) } }
                    .filter { $0.1 > currentRank }
                if let lowest = candidates.min(by: { $0.1 < $1.1 }) {
                    return .to(.rung(.effort(lowest.0)))
                }
            }
            return .to(remaining.first.map(ReasoningShape.rung) ?? .modelDefault(exhausted: true))
        }
    }

    private static let listLeads = [
        "supported values", "valid values", "allowed values", "supported:", "must be one of", "expected one of",
        "one of", "supported are", "accepted values",
    ]

    public static func listedEffortValues(in message: String) -> [String] {
        let lower = message.lowercased()
        if let lead = listLeads.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            return vocabularyWords(in: String(lower[lead.upperBound...]))
        }
        return quotedVocabularyWords(in: lower)
    }

    private static func vocabularyWords(in text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init).filter { rank($0) != nil }
    }

    private static func quotedVocabularyWords(in text: String) -> [String] {
        let pattern = #"['"`]([a-z]+)['"`]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { rank($0) != nil }
    }

    public static func classify(message: String) -> ReasoningRejection {
        let lower = message.lowercased()
        let listed = listedEffortValues(in: lower)
        let valuePhrases = ["invalid value", "unsupported value", "not a valid value", "is not a valid", "must be"]
        if !listed.isEmpty || valuePhrases.contains(where: lower.contains)
            || quotedVocabularyWords(in: lower).isEmpty == false {
            return .value(listed: listed)
        }
        let fieldPhrases = [
            "unsupported parameter", "unknown parameter", "unrecognized", "unknown name", "extra inputs",
            "extra_forbidden", "not permitted", "unexpected keyword", "unexpected field", "not a valid field",
            "not supported", "unsupported", "does not support",
        ]
        return fieldPhrases.contains(where: lower.contains) ? .unknownField : .value(listed: [])
    }
}

public enum ReasoningHeadroom {
    public static let extra = 6144

    public static func outputTokens(
        base: Int, shape: ReasoningShape, honored: Bool, reasoningModelHint: Bool, ceiling: Int?
    ) -> Int {
        let reasoningOff = shape.request?.disablesReasoning == true && honored && !reasoningModelHint
        let (raised, overflow) = base.addingReportingOverflow(extra)
        let sized = reasoningOff ? base : (overflow ? Int.max : raised)
        guard let ceiling, ceiling > 0 else { return sized }
        return min(sized, ceiling)
    }
}

public enum TokenLimitCap {
    private static let patterns = [
        #"less than or equal to\s+(\d+)"#, #"at most\s+(\d+)"#, #"<=\s*(\d+)"#, #"cannot exceed\s+(\d+)"#,
        #"must not exceed\s+(\d+)"#, #"up to\s+(\d+)"#, #">\s*(\d+),?\s*which is the maximum"#,
        #"maximum(?: allowed)?(?: value)?(?: number of output tokens)?(?: is| of)?\s*:?\s*(\d+)"#,
    ]
    private static let subjects = [
        "max_tokens", "max_completion_tokens", "max_output_tokens", "maxoutputtokens", "output tokens",
        "completion tokens", "max tokens",
    ]

    public static func parse(message: String) -> Int? {
        let lower = message.lowercased()
        guard subjects.contains(where: lower.contains), !lower.contains("context length") else { return nil }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let range = Range(match.range(at: 1), in: lower),
                  let value = Int(lower[range]), value > 0 else { continue }
            return value
        }
        return nil
    }
}

public struct ReplyUsage: Equatable, Sendable {
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var hadReasoningContent: Bool

    public init(outputTokens: Int? = nil, reasoningTokens: Int? = nil, hadReasoningContent: Bool = false) {
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.hadReasoningContent = hadReasoningContent
    }

    public var showsReasoning: Bool { (reasoningTokens ?? 0) > 0 || hadReasoningContent }

    public var evidence: ReasoningEvidence {
        if showsReasoning { return .reasoned }
        return reasoningTokens == 0 ? .none : .unreported
    }

    public static func openAIChat(_ json: [String: Any]) -> ReplyUsage {
        let usage = json["usage"] as? [String: Any]
        let details = usage?["completion_tokens_details"] as? [String: Any]
        let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        let hadContent = ["reasoning_content", "reasoning"].contains { nonEmptyText(message?[$0]) }
            || ((message?["reasoning_details"] as? [Any])?.isEmpty == false)
        return ReplyUsage(
            outputTokens: int(usage?["completion_tokens"]), reasoningTokens: int(details?["reasoning_tokens"]),
            hadReasoningContent: hadContent)
    }

    public static func openAIResponses(_ json: [String: Any]) -> ReplyUsage {
        let usage = json["usage"] as? [String: Any]
        let details = usage?["output_tokens_details"] as? [String: Any]
        let items = json["output"] as? [[String: Any]] ?? []
        return ReplyUsage(
            outputTokens: int(usage?["output_tokens"]), reasoningTokens: int(details?["reasoning_tokens"]),
            hadReasoningContent: items.contains { item in
                guard (item["type"] as? String) == "reasoning" else { return false }
                return ["summary", "content"].contains { ((item[$0] as? [Any])?.isEmpty == false) }
            })
    }

    public static func anthropic(_ json: [String: Any]) -> ReplyUsage {
        let usage = json["usage"] as? [String: Any]
        let details = usage?["output_tokens_details"] as? [String: Any]
        let blocks = json["content"] as? [[String: Any]] ?? []
        let thinkingTypes: Set<String> = ["thinking", "redacted_thinking"]
        return ReplyUsage(
            outputTokens: int(usage?["output_tokens"]), reasoningTokens: int(details?["thinking_tokens"]),
            hadReasoningContent: blocks.contains { thinkingTypes.contains($0["type"] as? String ?? "") })
    }

    public static func gemini(_ json: [String: Any]) -> ReplyUsage {
        let usage = json["usageMetadata"] as? [String: Any]
        let thoughts = int(usage?["thoughtsTokenCount"])
        let candidates = int(usage?["candidatesTokenCount"])
        let output = candidates.map { $0 + (thoughts ?? 0) } ?? thoughts
        let parts = (((json["candidates"] as? [[String: Any]])?.first)?["content"] as? [String: Any])?["parts"]
            as? [[String: Any]] ?? []
        return ReplyUsage(
            outputTokens: output, reasoningTokens: thoughts,
            hadReasoningContent: parts.contains { ($0["thought"] as? Bool) == true })
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }

    private static func nonEmptyText(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ReplyLimitVerdict: Equatable, Sendable {
    case ok
    case truncatedAnswer
    case limitBeforeAnswer(reasoningEvidence: Bool)
    case empty
}

public enum ReplyLimit {
    public static func verdict(limitHit: Bool, hasVisibleText: Bool, usage: ReplyUsage?) -> ReplyLimitVerdict {
        switch (limitHit, hasVisibleText) {
        case (true, false): .limitBeforeAnswer(reasoningEvidence: usage?.showsReasoning ?? false)
        case (true, true): .truncatedAnswer
        case (false, false): .empty
        case (false, true): .ok
        }
    }
}

// What replies have shown about reasoning. Only an explicit zero count confirms none: a service that omits
// the count (many proxies do) leaves the question open. Once a reply has reasoned, that sticks.
public enum ReasoningEvidence: Equatable, Sendable {
    case unreported, none, reasoned

    public func merged(with reply: ReasoningEvidence) -> ReasoningEvidence {
        if self == .reasoned || reply == .unreported { return self }
        return reply
    }
}

public struct ReasoningOutcome: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case off, offUnconfirmed, level, lowestAccepted, modelDefault, modelDefaultFallback, notSettable,
             notAdjustable, uncontrolledReasoning, notHonored, unenforced
    }

    public var kind: Kind
    public var level: String?

    public init(kind: Kind, level: String? = nil) {
        self.kind = kind
        self.level = level
    }

    public static func resolve(
        preference: ReasoningPreference, shape: ReasoningShape, evidence: ReasoningEvidence, enforced: Bool = true
    ) -> ReasoningOutcome {
        switch shape {
        case .unknown:
            switch evidence {
            case .reasoned: return ReasoningOutcome(kind: .uncontrolledReasoning)
            case .none: return ReasoningOutcome(kind: .notAdjustable)
            case .unreported: return ReasoningOutcome(kind: .notSettable)
            }
        case .modelDefault(let exhausted): return ReasoningOutcome(kind: exhausted ? .modelDefaultFallback : .modelDefault)
        case .rung(let request):
            if request.disablesReasoning {
                switch evidence {
                case .reasoned: return ReasoningOutcome(kind: .notHonored, level: request.levelName)
                case .none: return ReasoningOutcome(kind: .off)
                case .unreported where !enforced: return ReasoningOutcome(kind: .unenforced, level: request.levelName)
                case .unreported: return ReasoningOutcome(kind: .offUnconfirmed)
                }
            }
            if !enforced { return ReasoningOutcome(kind: .unenforced, level: request.levelName) }
            if preference == .lowestAvailable { return ReasoningOutcome(kind: .lowestAccepted, level: request.levelName) }
            return ReasoningOutcome(kind: .level, level: request.levelName)
        }
    }

    public var deservesNotice: Bool {
        [.modelDefaultFallback, .notSettable, .uncontrolledReasoning, .notHonored, .unenforced].contains(kind)
    }

    public var summary: String {
        let name = ReasoningReport.displayName(level ?? "")
        switch kind {
        case .off: return "Off"
        case .offUnconfirmed: return "Off — requested; the service doesn't confirm it"
        case .level: return name
        case .lowestAccepted: return "\(name) — the lowest this model accepts"
        case .modelDefault: return "Model default"
        case .modelDefaultFallback: return "Model default — no lower level was accepted"
        case .notSettable: return "Couldn't be set — the model decides"
        case .notAdjustable: return "Not adjustable — the model reported no reasoning"
        case .uncontrolledReasoning: return "Couldn't be set — the model reasoned on its own"
        case .notHonored: return "Not honored — the model reasoned anyway"
        case .unenforced: return "\(name) requested — not guaranteed; the service may ignore it"
        }
    }

    public static let noticeTitle = "Reasoning setting not applied"

    public func notice(service: String, model: String) -> String? {
        switch kind {
        case .notSettable:
            return "\(service) didn't accept a reasoning setting for \(model), so the model uses its own. Rewrites may be slower."
        case .modelDefaultFallback:
            return "\(service) didn't accept a lower reasoning level for \(model), so the model uses its own. Rewrites may be slower."
        case .uncontrolledReasoning:
            return "\(service) didn't accept a reasoning setting for \(model), and the model reasoned on its own. Rewrites may be slower."
        case .notHonored:
            return "\(model) on \(service) reasoned even with reasoning off. Rewrites may be slower."
        case .unenforced:
            return "\(service) had no provider for \(model) that guarantees the reasoning setting, so it may be ignored. Rewrites may be slower."
        default:
            return nil
        }
    }
}

public enum ReasoningReport {
    public static func displayName(_ level: String) -> String {
        switch level.lowercased() {
        case "xhigh": "Extra high"
        case "max": "Maximum"
        case "off": "Off"
        case "": "Unknown"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    public static func preferenceName(_ preference: ReasoningPreference) -> String {
        switch preference {
        case .lowestAvailable: "Recommended — least reasoning"
        case .modelDefault: "Model default"
        case .level(let level): displayName(level)
        }
    }
}

public struct ModelReasoningSupport: Equatable, Sendable {
    public var levels: [String]?
    public var canTurnOff: Bool?
    public var maxOutputTokens: Int?

    public init(levels: [String]? = nil, canTurnOff: Bool? = nil, maxOutputTokens: Int? = nil) {
        self.levels = levels
        self.canTurnOff = canTurnOff
        self.maxOutputTokens = maxOutputTokens
    }

    public var publishesReasoning: Bool { levels != nil || canTurnOff != nil }

    public static func openRouter(_ entry: [String: Any]) -> ModelReasoningSupport? {
        let parameters = entry["supported_parameters"] as? [String]
        let reasoning = entry["reasoning"] as? [String: Any]
        guard parameters != nil || reasoning != nil else { return nil }
        let ceiling = ((entry["top_provider"] as? [String: Any])?["max_completion_tokens"] as? NSNumber)?.intValue
        guard reasoning != nil || parameters?.contains("reasoning") == true else {
            return ModelReasoningSupport(levels: [], canTurnOff: true, maxOutputTokens: ceiling)
        }
        let listed = (reasoning?["supported_efforts"] as? [String])?.map { $0.lowercased() }
        let levels = listed.map { efforts in ReasoningPreference.levels.filter(efforts.contains) }
        let mandatory = reasoning?["mandatory"] as? Bool
        let offAllowed = mandatory.map { !$0 } ?? listed.map { $0.contains("none") }
        return ModelReasoningSupport(levels: levels, canTurnOff: offAllowed, maxOutputTokens: ceiling)
    }

    public static func gemini(_ entry: [String: Any]) -> ModelReasoningSupport? {
        guard let limit = (entry["outputTokenLimit"] as? NSNumber)?.intValue, limit > 0 else { return nil }
        return ModelReasoningSupport(maxOutputTokens: limit)
    }

    public static func anthropic(_ entry: [String: Any]) -> ModelReasoningSupport? {
        guard let thinking = (entry["capabilities"] as? [String: Any])?["thinking"] as? [String: Any],
              let types = thinking["types"] as? [String: Any] else { return nil }
        let disabled = (types["disabled"] as? [String: Any])?["supported"] as? Bool
        let betweenTools = (types["between_tools"] as? [String: Any])?["supported"] as? Bool
        guard disabled != nil || betweenTools != nil else { return nil }
        return ModelReasoningSupport(canTurnOff: disabled == true || betweenTools == true)
    }
}

public struct ModelListing: Equatable, Sendable {
    public var id: String
    public var reasoning: ModelReasoningSupport?

    public init(id: String, reasoning: ModelReasoningSupport? = nil) {
        self.id = id
        self.reasoning = reasoning
    }
}

public enum ReasoningChoices {
    public static func options(support: ModelReasoningSupport?, current: ReasoningPreference) -> [ReasoningPreference] {
        var options: [ReasoningPreference] = [.lowestAvailable]
        options += (support?.levels ?? ReasoningPreference.levels).map(ReasoningPreference.level)
        options.append(.modelDefault)
        if !options.contains(current) { options.insert(current, at: options.count - 1) }
        return options
    }

    public static func isListed(_ preference: ReasoningPreference, support: ModelReasoningSupport?) -> Bool {
        guard case .level(let level) = preference, let levels = support?.levels else { return true }
        return levels.contains(level)
    }

    public static func caption(support: ModelReasoningSupport?) -> String {
        guard let support, support.publishesReasoning else {
            return "Recommended asks for the least reasoning, for quicker rewrites. This service doesn't list supported levels. If an explicit level isn't accepted, the rewrite stops and says so."
        }
        if support.canTurnOff == false {
            return "This model always uses some reasoning. Recommended uses the least this model allows, for quicker rewrites."
        }
        if support.levels?.isEmpty == true {
            return "This model doesn't list any reasoning levels."
        }
        return "Recommended uses the least reasoning this model allows, for quicker rewrites. Higher levels take longer and need more output space."
    }
}
