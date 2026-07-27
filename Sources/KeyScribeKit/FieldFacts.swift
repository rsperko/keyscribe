import Foundation

public struct FieldFacts: Equatable, Sendable {
    public let singleLine: Bool?
    public let plainText: Bool?

    public init(singleLine: Bool?, plainText: Bool?) {
        self.singleLine = singleLine
        self.plainText = plainText
    }

    public static func derive(role: String?) -> FieldFacts {
        switch role {
        case "AXTextField": return FieldFacts(singleLine: true, plainText: nil)
        case "AXTextArea": return FieldFacts(singleLine: false, plainText: nil)
        default: return FieldFacts(singleLine: nil, plainText: nil)
        }
    }
}
