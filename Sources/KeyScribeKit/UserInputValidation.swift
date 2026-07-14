import Foundation

public enum UserInputValidation {
    public enum Issue: Equatable, Sendable {
        case empty
        case multipleLines
        case controlCharacters
        case tooLong(limit: Int)
        case invalidURL
        case credentialsNotAllowed
        case invalidRegex

        public var message: String {
            switch self {
            case .empty: "Enter a value."
            case .multipleLines: "Use one line."
            case .controlCharacters: "Remove control characters."
            case .tooLong(let limit): "Keep this to \(limit.formatted()) characters or fewer."
            case .invalidURL: "Enter a complete http or https URL."
            case .credentialsNotAllowed: "Remove the username and password from this URL."
            case .invalidRegex: "That is not a valid regular expression."
            }
        }
    }

    public static let nameLimit = 256
    public static let identifierLimit = 512
    public static let phraseLimit = 256
    public static let regexLimit = 4_096
    public static let endpointLimit = 2_048
    public static let secretLimit = 16_384
    public static let promptLimit = 65_536

    public static func nameIssue(_ value: String) -> Issue? {
        singleLineIssue(value, required: true, limit: nameLimit)
    }

    public static func identifierIssue(_ value: String, required: Bool = false) -> Issue? {
        singleLineIssue(value, required: required, limit: identifierLimit)
    }

    public static func phraseIssue(_ value: String) -> Issue? {
        singleLineIssue(value, required: true, limit: phraseLimit)
    }

    public static func endpointIssue(_ value: String) -> Issue? {
        if let issue = singleLineIssue(value, required: true, limit: endpointLimit) { return issue }
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http",
              components.host?.isEmpty == false
        else { return .invalidURL }
        guard components.user == nil, components.password == nil else { return .credentialsNotAllowed }
        return nil
    }

    public static func regexIssue(_ value: String) -> Issue? {
        if let issue = singleLineIssue(value, required: true, limit: regexLimit) { return issue }
        return RegexCache.isValidPattern(value) ? nil : .invalidRegex
    }

    public static func secretIssue(_ value: String) -> Issue? {
        if value.count > secretLimit { return .tooLong(limit: secretLimit) }
        return value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" })
            ? .controlCharacters
            : nil
    }

    public static func promptIssue(_ value: String) -> Issue? {
        if value.count > promptLimit { return .tooLong(limit: promptLimit) }
        return value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" })
            ? .controlCharacters
            : nil
    }

    private static func singleLineIssue(_ value: String, required: Bool, limit: Int) -> Issue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && trimmed.isEmpty { return .empty }
        if value.contains(where: { $0.isNewline }) { return .multipleLines }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return .controlCharacters }
        if value.count > limit { return .tooLong(limit: limit) }
        return nil
    }
}
