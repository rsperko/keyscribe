import KeyScribeKit

enum SpeechModelChoicePrimaryAction: Equatable {
    case current
    case use
    case download
    case downloading
    case testing
    case testAgain
    case useUnavailable
    case downloadUnavailable
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

    static let menuUnavailableReason = "can’t run in this build"

    static func unavailableReason(appName: String, isActive: Bool) -> String {
        let cause = "This build of \(appName) can’t load the GPU shaders this model needs."
        return isActive
            ? "\(cause) Choose another model to keep dictating."
            : "\(cause) Rebuild \(appName) with the Metal Toolchain installed to use it."
    }

    static func primaryAction(
        isActive: Bool,
        isUsable: Bool,
        isInstalled: Bool,
        isUnavailable: Bool,
        isDownloading: Bool,
        isVerifying: Bool,
        verificationFailed: Bool
    ) -> SpeechModelChoicePrimaryAction {
        if isUnavailable { return isInstalled ? .useUnavailable : .downloadUnavailable }
        if isDownloading { return .downloading }
        if isVerifying { return .testing }
        if verificationFailed { return .testAgain }
        if isActive { return .current }
        return isUsable ? .use : .download
    }
}
