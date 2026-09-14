import KeyScribeKit

enum SpeechModelChoicePrimaryAction: Equatable {
    case current
    case use
    case download
    case downloading
    case testing
    case testAgain
}

enum SpeechModelChoiceCopy {
    static func bestFor(_ info: SpeechModelInfo) -> String {
        switch info.id {
        case "parakeet": "Fast, accurate dictation for most people."
        case "apple": "No download and the fastest setup."
        default: info.summary
        }
    }

    static func memoryUse(for info: SpeechModelInfo) -> String {
        switch info.approxMemoryBytes {
        case 0: "Almost no memory"
        case ...600_000_000: "Light memory use"
        case ...2_000_000_000: "Moderate memory use"
        default: "High memory use"
        }
    }

    static func replacedActiveNotice(replacedId: String, replacementName: String, replacementUsable: Bool) -> String {
        let reason: String
        if let retiredName = SpeechModelCatalog.retiredDisplayNames[replacedId] {
            reason = "\(retiredName) is no longer included in \(Branding.appName)."
        } else if let unavailable = SpeechModelCatalog.entry(for: replacedId) {
            reason = "\(unavailable.displayName) isn’t available on this Mac."
        } else {
            reason = "Your saved speech model isn’t available."
        }
        let next = replacementUsable ? "Now using \(replacementName)." : "Download a model to keep dictating."
        return "\(reason) \(next)"
    }

    static func primaryAction(
        isActive: Bool,
        isUsable: Bool,
        isDownloading: Bool,
        isVerifying: Bool,
        verificationFailed: Bool
    ) -> SpeechModelChoicePrimaryAction {
        if isDownloading { return .downloading }
        if isVerifying { return .testing }
        if verificationFailed { return .testAgain }
        if isActive { return .current }
        return isUsable ? .use : .download
    }
}
