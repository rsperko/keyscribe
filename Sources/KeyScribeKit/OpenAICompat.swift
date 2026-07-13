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
    public var includeReasoningEffort: Bool
    public var includeThinkingConfig: Bool

    public init(
        tokenLimitField: TokenLimitField,
        includeTemperature: Bool = true,
        foldSystemIntoUser: Bool = false,
        includeReasoningEffort: Bool = true,
        includeThinkingConfig: Bool = true
    ) {
        self.tokenLimitField = tokenLimitField
        self.includeTemperature = includeTemperature
        self.foldSystemIntoUser = foldSystemIntoUser
        self.includeReasoningEffort = includeReasoningEffort
        self.includeThinkingConfig = includeThinkingConfig
    }

    public static func `default`(for provider: Connection.Provider) -> RequestAdaptations {
        switch provider {
        case .openai: RequestAdaptations(tokenLimitField: .maxCompletionTokens)
        case .openaiCompatible, .anthropic, .gemini: RequestAdaptations(tokenLimitField: .maxTokens)
        }
    }

    public var indicatesReasoningModel: Bool {
        !includeTemperature || foldSystemIntoUser
    }
}

public struct OpenAIAPIError: Equatable, Sendable {
    public let code: String?
    public let param: String?
    // The prose error message. A proxy fronting a non-OpenAI backend (Azure, a vLLM gateway, a corporate
    // relay) often rejects a parameter with a plain 400 that carries no machine-readable `param`/`code` —
    // only this string. Captured so remediation can still recover by scanning it.
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

    // The `error` object, whether the body is a plain `{"error": {...}}` or a single-element top-level
    // array `[{"error": {...}}]` — the shape a proxy fronting another backend (e.g. one wrapping Gemini)
    // can emit. Anything else (a bare list, a non-error object) yields nil.
    private static func errorObject(in json: Any) -> [String: Any]? {
        if let object = json as? [String: Any] { return object["error"] as? [String: Any] }
        if let array = json as? [Any], let first = array.first { return errorObject(in: first) }
        return nil
    }

    public var indicatesMissingModel: Bool {
        switch code {
        case "model_not_found", "model_not_available", "invalid_model": true
        default: param == "model"
        }
    }
}

// Params we can safely drop or remap when a server rejects them. Bounded on purpose: message-scanning
// never strips something we didn't send or can't act on, so a stray param name in an error message can't
// silently disable an unrelated part of the request.
private let messageScannableParams = ["reasoning_effort", "temperature", "max_tokens"]

public func remediatedAdaptations(
    _ current: RequestAdaptations, for error: OpenAIAPIError
) -> RequestAdaptations? {
    // Structured path: a well-formed OpenAI error names the offending param directly. Precise, so it wins.
    let remediableCodes: Set<String> = ["unsupported_parameter", "unsupported_value"]
    if let code = error.code, remediableCodes.contains(code), let param = error.param,
       let next = adaptationDroppingParam(param, from: current) {
        return next
    }

    // Message-scan fallback: no usable structured param, so recover from the prose. Strip the first param we
    // sent that the message names, most-specific intent first. `contains` is safe here because "max_tokens"
    // is not a substring of "max_completion_tokens", and each drop is guarded on the param currently being
    // enabled — so we never remap the token field the wrong way or drop a param twice. The remediation loop
    // is bounded, and RequestAdaptationCache remembers the result, so this self-heals after the first hit.
    if let message = error.message?.lowercased() {
        for param in messageScannableParams where message.contains(param) {
            if let next = adaptationDroppingParam(param, from: current) { return next }
        }
        // System-role rejection: some models/proxies reject the `system` role with a generic 400 (no
        // structured `messages[N].role` param). Fold the system message into the user turn — `user` is
        // universally accepted. Two-token guard — BOTH a role word AND a role name — so an incidental
        // "system" ("system is busy") or "role" ("your account role") can't trigger a pointless fold.
        if message.contains("role"), message.contains("system") || message.contains("assistant"),
           let next = adaptationDroppingParam("messages[0].role", from: current) {
            return next
        }
    }
    return nil
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
    case "reasoning_effort":
        guard current.includeReasoningEffort else { return nil }
        next.includeReasoningEffort = false
    default:
        guard param.range(of: #"^messages\[\d+\]\.role$"#, options: .regularExpression) != nil,
              !current.foldSystemIntoUser else { return nil }
        next.foldSystemIntoUser = true
    }
    return next == current ? nil : next
}

public enum ReasoningOutput {
    public static func clean(_ raw: String) -> String? {
        var text = raw
        for tag in ["think", "thinking", "reasoning", "thought"] {
            text = text.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public func reasoningSafeMaxTokens(_ current: Int, floor: Int = 8192) -> Int {
    max(current, floor)
}
