import Foundation

public enum EngineKind: String, Codable, Sendable, Equatable {
    case parakeet, whisper, apple, qwen3asr
}

// Graded against the best model offered rather than a fixed scale, so the top label always means "nothing
// here does better" (rule in docs/reference/stt_benchmarks.md).
public enum SpeechAccuracy: Int, Sendable, Comparable, CaseIterable {
    case lower, good, high, top

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func grade(averageWER: Double, best: Double) -> SpeechAccuracy {
        switch averageWER - best {
        case ...1.0: .top
        case ...2.5: .high
        case ...5.0: .good
        default: .lower
        }
    }
}

public enum SpeechSpeed: Int, Sendable, Comparable, CaseIterable {
    case slower, fast, fastest

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func grade(realTimeFactor: Double, fastest: Double) -> SpeechSpeed {
        switch realTimeFactor / fastest {
        case ...2.5: .fastest
        case ...8.0: .fast
        default: .slower
        }
    }
}

public struct SpeechModelInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: EngineKind
    public let displayName: String
    public let summary: String
    public let languageCount: Int?
    public let approxDownloadBytes: Int64
    // Resident memory while dictating (wired-inclusive, measured via `--mem-probe`). On Apple Silicon the
    // accelerator wires model weights into RAM outside this process's footprint, so this is far more honest
    // than Activity Monitor's per-app figure. Single machine, ±20%.
    public let approxMemoryBytes: Int64
    public let systemManaged: Bool
    public let isDefaultEnglish: Bool
    public let supportsRecognitionBias: Bool
    // Measured, never tuned: no-dictionary WER averaged over the quiet and noisy corpora, and warm-engine
    // processing time over audio length. Re-measure when a model is added or an engine dependency moves.
    public let averageWER: Double
    public let realTimeFactor: Double
    // Still works and stays installable, but is no longer offered to new users; it is retired (moved to
    // `retiredDisplayNames`) no sooner than a release after it turns legacy.
    public let isLegacy: Bool

    public init(
        id: String, kind: EngineKind, displayName: String, summary: String, languageCount: Int?,
        approxDownloadBytes: Int64, systemManaged: Bool, isDefaultEnglish: Bool,
        supportsRecognitionBias: Bool, averageWER: Double, realTimeFactor: Double, approxMemoryBytes: Int64 = 0,
        isLegacy: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.summary = summary
        self.languageCount = languageCount
        self.approxDownloadBytes = approxDownloadBytes
        self.approxMemoryBytes = approxMemoryBytes
        self.systemManaged = systemManaged
        self.isDefaultEnglish = isDefaultEnglish
        self.supportsRecognitionBias = supportsRecognitionBias
        self.averageWER = averageWER
        self.realTimeFactor = realTimeFactor
        self.isLegacy = isLegacy
    }

    public var accuracy: SpeechAccuracy {
        .grade(averageWER: averageWER, best: SpeechModelCatalog.bestAverageWER(in: SpeechModelCatalog.all))
    }

    public var speed: SpeechSpeed {
        .grade(realTimeFactor: realTimeFactor, fastest: SpeechModelCatalog.fastestRealTimeFactor(in: SpeechModelCatalog.all))
    }
}

public enum SpeechModelCatalog {
    public static let all: [SpeechModelInfo] = [
        SpeechModelInfo(
            id: "parakeet-ultra", kind: .parakeet, displayName: "Parakeet Ultra",
            summary: "Retrained Parakeet TDT v3 — more accurate at the same speed.",
            languageCount: 25, approxDownloadBytes: 630_000_000, systemManaged: false,
            isDefaultEnglish: true, supportsRecognitionBias: false, averageWER: 8.2, realTimeFactor: 0.009,
            approxMemoryBytes: 515_000_000),
        SpeechModelInfo(
            id: "parakeet", kind: .parakeet, displayName: "Parakeet TDT v3",
            summary: "Original multilingual Parakeet — smaller download than Ultra.",
            languageCount: 25, approxDownloadBytes: 480_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: false, averageWER: 10.15, realTimeFactor: 0.009,
            approxMemoryBytes: 515_000_000),
        SpeechModelInfo(
            id: "parakeet-unified-en", kind: .parakeet,
            displayName: "Parakeet Unified 0.6B (English)",
            summary: "English only — writes punctuation and capitalization for you.",
            languageCount: 1, approxDownloadBytes: 614_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: false, averageWER: 8.6, realTimeFactor: 0.009,
            approxMemoryBytes: 685_000_000),
        SpeechModelInfo(
            id: "whisper-small-en", kind: .whisper, displayName: "Whisper Small (English)",
            summary: "Smaller than Whisper Large v3 Turbo, with lower accuracy.",
            languageCount: 1, approxDownloadBytes: 220_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true, averageWER: 11.05, realTimeFactor: 0.059,
            approxMemoryBytes: 1_200_000_000),
        SpeechModelInfo(
            id: "whisper", kind: .whisper, displayName: "Whisper Large v3 Turbo",
            summary: "The most languages.",
            languageCount: 99, approxDownloadBytes: 648_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true, averageWER: 7.85, realTimeFactor: 0.116,
            approxMemoryBytes: 3_700_000_000),
        SpeechModelInfo(
            id: "qwen3-asr-0.6b", kind: .qwen3asr, displayName: "Qwen3-ASR 0.6B",
            summary: "Smaller than Qwen3-ASR 1.7B, with lower accuracy.",
            languageCount: 52, approxDownloadBytes: 713_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true, averageWER: 12.45, realTimeFactor: 0.015,
            approxMemoryBytes: 1_700_000_000),
        SpeechModelInfo(
            id: "qwen3-asr-1.7b", kind: .qwen3asr, displayName: "Qwen3-ASR 1.7B",
            summary: "Multilingual, and faster than Whisper Large v3 Turbo.",
            languageCount: 52, approxDownloadBytes: 2_470_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true, averageWER: 8.2, realTimeFactor: 0.039,
            approxMemoryBytes: 3_300_000_000),
        SpeechModelInfo(
            id: "apple", kind: .apple, displayName: "Apple Speech",
            summary: "Native macOS transcription. No download, fastest startup.",
            languageCount: nil, approxDownloadBytes: 0, systemManaged: true,
            isDefaultEnglish: false, supportsRecognitionBias: false, averageWER: 13.2, realTimeFactor: 0.019),
        SpeechModelInfo(
            id: "parakeet-tdt-ctc-110m", kind: .parakeet, displayName: "Parakeet TDT-CTC 110M",
            summary: "Compact English model — fast and small.",
            languageCount: 1, approxDownloadBytes: 330_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: false, averageWER: 15.45, realTimeFactor: 0.003,
            approxMemoryBytes: 250_000_000, isLegacy: true),
    ]

    // Models that no longer ship, kept so a saved setting that still names one can say what replaced it.
    public static let retiredDisplayNames: [String: String] = [
        "moonshine-base-en": "Moonshine Base (English)",
    ]

    public static func entry(for id: String) -> SpeechModelInfo? {
        all.first { $0.id == id }
    }

    public static func bestAverageWER(in catalog: [SpeechModelInfo]) -> Double {
        catalog.filter { !$0.isLegacy }.map(\.averageWER).min() ?? 0
    }

    public static func fastestRealTimeFactor(in catalog: [SpeechModelInfo]) -> Double {
        catalog.filter { !$0.isLegacy }.map(\.realTimeFactor).min() ?? 1
    }

    public static var defaultEnglishId: String {
        all.first(where: \.isDefaultEnglish)?.id ?? all[0].id
    }
}
