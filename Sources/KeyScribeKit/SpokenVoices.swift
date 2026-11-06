import Foundation

public struct SpokenVoice: Identifiable, Equatable, Sendable {
    public let id: String

    public var name: String {
        let base = id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? id
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    public var accent: String { id.hasPrefix("b") ? "British" : "American" }
    public var gender: String { id.dropFirst().hasPrefix("f") ? "female" : "male" }

    public var label: String {
        let label = "\(name) \u{00B7} \(accent), \(gender)"
        return id == SpokenVoices.recommended ? "\(label) (Recommended)" : label
    }
}

public enum SpokenVoices {
    public static let recommended = "af_heart"
    public static let sample = "Done. The tests pass, and one question is waiting for you."

    public static let all: [SpokenVoice] = {
        let ids = [
            "af_aoede", "af_bella", "af_heart", "af_kore", "af_nicole", "af_sarah",
            "am_fenrir", "am_michael", "am_puck", "bf_emma",
        ]
        return ([recommended] + ids.filter { $0 != recommended }.sorted()).map(SpokenVoice.init)
    }()

    public static func resolved(_ saved: String?) -> String {
        guard let saved, all.contains(where: { $0.id == saved }) else { return recommended }
        return saved
    }
}
