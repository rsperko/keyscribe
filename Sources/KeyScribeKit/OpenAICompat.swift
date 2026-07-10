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

    public init(
        tokenLimitField: TokenLimitField,
        includeTemperature: Bool = true,
        foldSystemIntoUser: Bool = false
    ) {
        self.tokenLimitField = tokenLimitField
        self.includeTemperature = includeTemperature
        self.foldSystemIntoUser = foldSystemIntoUser
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

    public init(code: String?, param: String?) {
        self.code = code
        self.param = param
    }

    public static func parse(body: String?) -> OpenAIAPIError? {
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String
        let param = error["param"] as? String
        guard code != nil || param != nil else { return nil }
        return OpenAIAPIError(code: code, param: param)
    }

    public var indicatesMissingModel: Bool {
        switch code {
        case "model_not_found", "model_not_available", "invalid_model": true
        default: param == "model"
        }
    }
}

public func remediatedAdaptations(
    _ current: RequestAdaptations, for error: OpenAIAPIError
) -> RequestAdaptations? {
    let remediableCodes: Set<String> = ["unsupported_parameter", "unsupported_value"]
    guard let code = error.code, remediableCodes.contains(code), let param = error.param else { return nil }

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
