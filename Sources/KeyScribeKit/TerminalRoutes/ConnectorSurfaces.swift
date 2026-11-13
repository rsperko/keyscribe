import Foundation

public struct ConnectorSurfaces: Equatable, Sendable, Encodable {
    public let environmentKeys: [String]
    public let focusDefinitions: [FocusDefinition]

    public init(environmentKeys: Set<String>, focusDefinitions: [FocusDefinition] = []) {
        self.environmentKeys = environmentKeys.sorted()
        self.focusDefinitions = focusDefinitions.sorted { $0.id < $1.id }
    }

    public init(_ surfaces: ResolvedSurfaces) {
        self.init(environmentKeys: surfaces.environmentKeys, focusDefinitions: surfaces.focusDefinitions)
    }

    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public var configFields: [String: Any] {
        [
            "environmentKeys": environmentKeys,
            "focusDefinitions": focusDefinitions.map { ["id": $0.id, "requiresEnv": $0.requiresEnv, "argv": $0.argv] },
        ]
    }
}
