import Foundation

// Legacy marker for global macOS audio state that earlier builds changed during dictation and might have
// stranded after a crash. Current builds only decode, reconcile, and clear it. Identity is by stable device
// UID, never transient AudioDeviceID.
public struct PendingSystemRestore: Decodable, Equatable, Sendable {
    // The user's original system default input device UID from a legacy marker.
    public var defaultInputUID: String?
    // Output mute marker decoded from earlier builds. Never encoded by current builds.
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

    // Undecodable bytes decode to nil so the launch reconcile leaves an unreadable marker untouched rather
    // than treating it as empty and clearing it.
    public static func decode(from data: Data) -> PendingSystemRestore? {
        try? JSONDecoder().decode(PendingSystemRestore.self, from: data)
    }
}
