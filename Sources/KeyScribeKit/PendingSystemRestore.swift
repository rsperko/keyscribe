import Foundation

// Legacy marker for audio state that earlier builds could strand after a crash.
public struct PendingSystemRestore: Decodable, Equatable, Sendable {
    public var defaultInputUID: String?
    public var legacyMutedOutputUID: String?

    public init(defaultInputUID: String? = nil, legacyMutedOutputUID: String? = nil) {
        self.defaultInputUID = defaultInputUID
        self.legacyMutedOutputUID = legacyMutedOutputUID
    }

    public var isEmpty: Bool { defaultInputUID == nil && legacyMutedOutputUID == nil }

    enum CodingKeys: String, CodingKey {
        case defaultInputUID
        case outputMute
    }

    private struct LegacyOutputMute: Decodable { let deviceUID: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultInputUID = try c.decodeIfPresent(String.self, forKey: .defaultInputUID)
        legacyMutedOutputUID =
            (try? c.decodeIfPresent(LegacyOutputMute.self, forKey: .outputMute))??.deviceUID
    }

    public static func decode(from data: Data) -> PendingSystemRestore? {
        try? JSONDecoder().decode(PendingSystemRestore.self, from: data)
    }
}
