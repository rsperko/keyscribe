import Foundation

public enum TokenLimitField: String, Equatable, Sendable {
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"

    public var jsonKey: String { rawValue }
}

public struct RequestAdaptations: Equatable, Sendable {
    public var tokenLimitField: TokenLimitField
    public var includeTemperature: Bool
    public var foldSystemIntoUser: Bool
    public var reasoning: ReasoningShape
    public var reasoningEvidence: ReasoningEvidence
    public var tokenLimitCap: Int?
    public var requireAllParameters: Bool

    public init(
        tokenLimitField: TokenLimitField,
        includeTemperature: Bool = true,
        foldSystemIntoUser: Bool = false,
        reasoning: ReasoningShape = .modelDefault(exhausted: false),
        reasoningEvidence: ReasoningEvidence = .unreported,
        tokenLimitCap: Int? = nil,
        requireAllParameters: Bool = true
    ) {
        self.tokenLimitField = tokenLimitField
        self.includeTemperature = includeTemperature
        self.foldSystemIntoUser = foldSystemIntoUser
        self.reasoning = reasoning
        self.reasoningEvidence = reasoningEvidence
        self.tokenLimitCap = tokenLimitCap
        self.requireAllParameters = requireAllParameters
    }

    public static func `default`(for provider: Connection.Provider) -> RequestAdaptations {
        switch provider {
        case .openai: RequestAdaptations(tokenLimitField: .maxCompletionTokens)
        case .openaiCompatible, .anthropic, .gemini: RequestAdaptations(tokenLimitField: .maxTokens)
        }
    }

    public static func initial(for connection: Connection) -> RequestAdaptations {
        var adaptations = RequestAdaptations.default(for: connection.provider)
        adaptations.reasoning = ReasoningLadder.initialShape(for: connection.params.reasoning, provider: connection.provider)
        return adaptations
    }

    public var indicatesReasoningModel: Bool {
        !includeTemperature || foldSystemIntoUser
    }

    public func outputTokens(base: Int, ceiling: Int?) -> Int {
        let cap = [ceiling, tokenLimitCap].compactMap { $0 }.min()
        return ReasoningHeadroom.outputTokens(
            base: base, shape: reasoning, honored: reasoningEvidence != .reasoned,
            reasoningModelHint: indicatesReasoningModel, ceiling: cap)
    }

    public func outcome(for preference: ReasoningPreference) -> ReasoningOutcome {
        ReasoningOutcome.resolve(
            preference: preference, shape: reasoning, evidence: reasoningEvidence, enforced: requireAllParameters)
    }
}

public struct OpenAIAPIError: Equatable, Sendable {
    public let code: String?
    public let param: String?
    public let message: String?

    public init(code: String?, param: String?, message: String? = nil) {
        self.code = code
        self.param = param
        self.message = message
    }

    public static func parse(body: String?) -> OpenAIAPIError? {
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let error = errorObject(in: json) else { return nil }
        // Some proxies return `code` as an integer (e.g. the HTTP status) rather than an OpenAI string code.
        let code = (error["code"] as? String) ?? (error["code"] as? Int).map(String.init)
        let param = error["param"] as? String
        let message = error["message"] as? String
        guard code != nil || param != nil || message != nil else { return nil }
        return OpenAIAPIError(code: code, param: param, message: message)
    }

    private static func errorObject(in json: Any) -> [String: Any]? {
        if let object = json as? [String: Any] {
            if let error = object["error"] as? [String: Any] { return error }
            // Some proxies return a string-valued `error` (a bare type name) and put the actionable text in
            // a top-level field. Synthesize an error object from the most-actionable one, most-specific
            // first; `reason` beats `description` because a proxy's `description` is generic boilerplate
            // while `reason` carries the remediation. A string `error` alone (no actionable text) stays
            // unparseable so an opaque body isn't mistaken for a structured error.
            if let message = topLevelMessage(in: object) {
                var synthesized: [String: Any] = ["message": message]
                if let code = object["error"] as? String { synthesized["code"] = code }
                return synthesized
            }
        }
        if let array = json as? [Any], let first = array.first { return errorObject(in: first) }
        return nil
    }

    private static func topLevelMessage(in object: [String: Any]) -> String? {
        for key in ["message", "detail", "reason", "description"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    public var indicatesMissingModel: Bool {
        switch code {
        case "model_not_found", "model_not_available", "invalid_model": true
        default: param == "model"
        }
    }

    public func indicatesRequires(_ wireAPI: Connection.WireAPI) -> Bool {
        switch wireAPI {
        case .responses: indicatesRequiresResponsesAPI
        case .chatCompletions: indicatesRequiresChatCompletionsAPI
        case .auto: false
        }
    }

    public var indicatesRequiresResponsesAPI: Bool {
        guard let message = message?.lowercased() else { return false }
        if message.contains("not a chat model") { return true }   // wrong model *type* names its own subject
        return Self.pointsTo(Self.responsesCores, over: Self.chatCores, in: message)
    }

    public var indicatesRequiresChatCompletionsAPI: Bool {
        guard let message = message?.lowercased() else { return false }
        if message.contains("not a responses model") { return true }
        return Self.pointsTo(Self.chatCores, over: Self.responsesCores, in: message)
    }

    private static let responsesCores = ["responses"]
    private static let chatCores = ["chat/completions", "chat completions", "chat-completions"]
    // Phrases that introduce the endpoint the caller should switch TO. Kept off bare "supported in" so the
    // negation "not supported in {failed}" can never read as a recommendation of the failed endpoint.
    private static let redirectLeads = [
        "did you mean to use", "did you mean", "please use", "use the", "use v1", "use /", "switch to",
        "only supported in", "only available in", "must use", "requires",
    ]

    // True when a redirect phrase is followed by the target endpoint BEFORE any mention of the other. The
    // canonical wrong-endpoint error names both endpoints ("not supported in {A}. Did you mean {B}?"), so a
    // plain token match is ambiguous; attributing the message to the endpoint a redirect actually points at
    // makes the two detectors mutually exclusive on that shape.
    private static func pointsTo(_ target: [String], over other: [String], in message: String) -> Bool {
        for lead in redirectLeads {
            guard let leadRange = message.range(of: lead) else { continue }
            let after = message[leadRange.upperBound...]
            guard let targetPos = target.compactMap({ after.range(of: $0)?.lowerBound }).min() else { continue }
            let otherPos = other.compactMap { after.range(of: $0)?.lowerBound }.min()
            if otherPos == nil || targetPos < otherPos! { return true }
        }
        return false
    }
}

public enum Remediation: Equatable, Sendable {
    case retry(RequestAdaptations)
    case refuse(level: String)
}

// Params we can safely drop or remap when a server rejects them. Bounded on purpose: message-scanning
// never strips something we didn't send or can't act on, so a stray param name in an error message can't
// silently disable an unrelated part of the request.
private let messageScannableParams = ["temperature", "max_tokens"]

private let reasoningParams: Set<String> = [
    "reasoning_effort", "reasoning", "reasoning.effort", "thinking", "thinking.type", "output_config",
    "output_config.effort", "thinkingconfig", "thinkinglevel", "thinkingbudget",
    "generationconfig.thinkingconfig", "generation_config.thinking_config",
]

private func reasoningMessageTokens(for provider: Connection.Provider) -> [String] {
    switch provider {
    case .openai, .openaiCompatible: ["reasoning"]
    case .anthropic: ["thinking", "output_config", "effort"]
    case .gemini: ["thinking", "budget"]
    }
}

public func remediation(
    _ current: RequestAdaptations, for error: OpenAIAPIError,
    preference: ReasoningPreference = .lowestAvailable, provider: Connection.Provider = .openaiCompatible,
    sentTokenLimit: Int? = nil
) -> Remediation? {
    let openAIShaped = provider == .openai || provider == .openaiCompatible
    let remediableCodes: Set<String> = ["unsupported_parameter", "unsupported_value", "invalid_value"]
    if let code = error.code, remediableCodes.contains(code), let param = error.param {
        if reasoningParams.contains(param.lowercased()) {
            let rejection: ReasoningRejection = code == "unsupported_parameter"
                ? .unknownField : .value(listed: ReasoningLadder.listedEffortValues(in: error.message ?? ""))
            if let step = reasoningRemediation(current, rejection: rejection, preference: preference, provider: provider) {
                return step
            }
        } else if openAIShaped, let next = adaptationDroppingParam(param, from: current) {
            return .retry(next)
        }
    }

    guard let message = error.message?.lowercased() else { return nil }

    if let cap = TokenLimitCap.parse(message: message), let sent = sentTokenLimit, cap < sent,
       current.tokenLimitCap.map({ cap < $0 }) ?? true {
        var next = current
        next.tokenLimitCap = cap
        return .retry(next)
    }

    if !openAIShaped, current.includeTemperature, message.contains("temperature") {
        var next = current
        next.includeTemperature = false
        return .retry(next)
    }

    if reasoningMessageTokens(for: provider).contains(where: message.contains),
       let step = reasoningRemediation(
           current, rejection: ReasoningLadder.classify(message: message), preference: preference, provider: provider) {
        return step
    }

    guard openAIShaped else { return nil }
    // Message-scan fallback: no usable structured param, so recover from the prose. `contains` is safe here
    // because "max_tokens" is not a substring of "max_completion_tokens", and each drop is guarded on the
    // param currently being enabled — so we never remap the token field the wrong way or drop a param twice.
    for param in messageScannableParams where message.contains(param) {
        if let next = adaptationDroppingParam(param, from: current) { return .retry(next) }
    }
    // System-role rejection: some models/proxies reject the `system` role with a generic 400 (no
    // structured `messages[N].role` param). Fold the system message into the user turn — `user` is
    // universally accepted. Two-token guard — BOTH a role word AND a role name — so an incidental
    // "system" ("system is busy") or "role" ("your account role") can't trigger a pointless fold.
    if message.contains("role"), message.contains("system") || message.contains("assistant"),
       let next = adaptationDroppingParam("messages[0].role", from: current) {
        return .retry(next)
    }
    return nil
}

public func remediatedAdaptations(
    _ current: RequestAdaptations, for error: OpenAIAPIError,
    preference: ReasoningPreference = .lowestAvailable, provider: Connection.Provider = .openaiCompatible
) -> RequestAdaptations? {
    guard case .retry(let next) = remediation(current, for: error, preference: preference, provider: provider) else {
        return nil
    }
    return next
}

private func reasoningRemediation(
    _ current: RequestAdaptations, rejection: ReasoningRejection, preference: ReasoningPreference,
    provider: Connection.Provider
) -> Remediation? {
    guard let step = ReasoningLadder.step(
        from: current.reasoning, preference: preference, provider: provider, rejection: rejection) else { return nil }
    switch step {
    case .refuse(let level):
        return .refuse(level: level)
    case .to(let shape):
        var next = current
        next.reasoning = shape
        return next == current ? nil : .retry(next)
    }
}

private func adaptationDroppingParam(
    _ param: String, from current: RequestAdaptations
) -> RequestAdaptations? {
    var next = current
    switch param {
    case "max_tokens":
        guard current.tokenLimitField == .maxTokens else { return nil }
        next.tokenLimitField = .maxCompletionTokens
    case "temperature":
        guard current.includeTemperature else { return nil }
        next.includeTemperature = false
    default:
        guard param.range(of: #"^messages\[\d+\]\.role$"#, options: .regularExpression) != nil,
              !current.foldSystemIntoUser else { return nil }
        next.foldSystemIntoUser = true
    }
    return next == current ? nil : next
}

public enum ReasoningOutput {
    private static let tags = ["think", "thinking", "reasoning", "thought"]

    public static func clean(_ raw: String) -> String? {
        var text = raw
        for tag in tags {
            text = text.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "",
                options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(
                of: "^\\s*<\(tag)>[\\s\\S]*$", with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func containsReasoning(_ raw: String) -> Bool {
        tags.contains { raw.range(of: "<\($0)>", options: .caseInsensitive) != nil }
    }
}
