import Foundation

public enum AppleSpeechModel: String, Sendable, CaseIterable {
    case speech
    case dictation

    public static let overrideEnvironmentKey = "KEYSCRIBE_APPLE_MODEL"

    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }

    public static func override(in environment: [String: String]) -> AppleSpeechModel? {
        environment[overrideEnvironmentKey].flatMap(AppleSpeechModel.init(argument:))
    }
}

public struct AppleSpeechModelChoice: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case preferred
        case macUnsupported
        case languageUnsupported
        case forced
        case speechDownloadFailed
    }

    public let model: AppleSpeechModel?
    public let reason: Reason

    public init(model: AppleSpeechModel?, reason: Reason) {
        self.model = model
        self.reason = reason
    }

    public func afterSpeechFailedToLoad(dictationSupportsLocale: Bool) -> AppleSpeechModelChoice? {
        guard model == .speech, dictationSupportsLocale else { return nil }
        return AppleSpeechModelChoice(model: .dictation, reason: .speechDownloadFailed)
    }

    public static func coveredLocale(_ mapped: Locale?, supported: [Locale]) -> Locale? {
        guard let mapped else { return nil }
        let tag = mapped.identifier(.bcp47)
        return supported.contains { $0.identifier(.bcp47) == tag } ? mapped : nil
    }

    public static func resolve(
        speechAvailable: Bool, speechSupportsLocale: Bool, dictationSupportsLocale: Bool, forced: AppleSpeechModel?
    ) -> AppleSpeechModelChoice {
        let fallback: AppleSpeechModel? = dictationSupportsLocale ? .dictation : nil
        if !speechAvailable {
            let reason: Reason = fallback == nil ? .languageUnsupported : .macUnsupported
            return AppleSpeechModelChoice(model: fallback, reason: reason)
        }
        if !speechSupportsLocale { return AppleSpeechModelChoice(model: fallback, reason: .languageUnsupported) }
        if forced == .dictation, dictationSupportsLocale {
            return AppleSpeechModelChoice(model: .dictation, reason: .forced)
        }
        return AppleSpeechModelChoice(model: .speech, reason: .preferred)
    }
}
