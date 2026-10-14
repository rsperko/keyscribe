import Foundation
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
        if info.isDefaultEnglish { return "Fast, accurate dictation for most people." }
        return info.id == "apple" ? "No download and the fastest setup." : info.summary
    }

    static func accuracy(_ accuracy: SpeechAccuracy) -> String {
        switch accuracy {
        case .top: "Top accuracy"
        case .high: "High accuracy"
        case .good: "Good accuracy"
        case .lower: "Lower accuracy"
        }
    }

    static func dictionaryNote(_ info: SpeechModelInfo) -> String? {
        info.supportsRecognitionBias ? "Better with names and jargon you add to your dictionary" : nil
    }

    static func accuracyLine(_ info: SpeechModelInfo) -> String {
        [accuracy(info.accuracy), dictionaryNote(info)].compactMap { $0 }.joined(separator: " · ")
    }

    static func speed(_ speed: SpeechSpeed) -> String {
        switch speed {
        case .fastest: "Fastest processing"
        case .fast: "Fast processing"
        case .slower: "Slower processing"
        }
    }

    @MainActor static func setupChoiceLabel(_ info: SpeechModelInfo) -> String {
        let prefix = info.isDefaultEnglish ? "Recommended: " : ""
        return "\(prefix)\(info.displayName) — \(accuracy(info.accuracy)) · \(languageScope(info)) · \(footprint(info))"
    }

    @MainActor static func footprint(_ info: SpeechModelInfo) -> String {
        info.systemManaged
            ? "built into macOS"
            : ByteCountFormatter.fileStyle.string(fromByteCount: info.approxDownloadBytes)
    }

    static func setupPrimaryAction(_ info: SpeechModelInfo) -> String {
        if info.systemManaged { return "Use \(info.displayName)" }
        return info.isDefaultEnglish ? "Download Recommended Model" : "Download \(info.displayName)"
    }

    static func legacyNotice(for info: SpeechModelInfo) -> String? {
        guard info.isLegacy else { return nil }
        let recommended = SpeechModelCatalog.entry(for: SpeechModelCatalog.defaultEnglishId)?.displayName
            ?? SpeechModelCatalog.defaultEnglishId
        return "Being phased out. Switch to \(recommended), the recommended model."
    }

    static func languageScope(_ info: SpeechModelInfo) -> String {
        guard let count = info.languageCount else { return "Languages vary by Mac" }
        return count <= 1 ? "English" : "\(count) languages"
    }

    static func appleModelStatus(_ choice: AppleSpeechModelChoice, languageName: String) -> String {
        guard choice.model != nil else { return "Apple Speech isn’t available for \(languageName)" }
        let fallback = "Using Apple Dictation (compatibility mode) — "
        switch choice.reason {
        case .preferred: return "Using Apple Speech"
        case .macUnsupported: return fallback + "Apple Speech isn’t available on this Mac"
        case .languageUnsupported: return fallback + "Apple Speech isn’t available for \(languageName)"
        case .forced: return fallback + "selected for testing"
        case .speechDownloadFailed: return fallback + "Apple Speech couldn’t be downloaded yet"
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
