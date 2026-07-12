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
