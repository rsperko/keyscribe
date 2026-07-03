import Foundation

public enum EngineKind: String, Codable, Sendable, Equatable {
    case parakeet, whisper, apple, qwen3asr, moonshine
}

public struct SpeechModelInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: EngineKind
    public let displayName: String
    public let summary: String
    public let languageCount: Int
    public let approxDownloadBytes: Int64
    public let systemManaged: Bool
    public let isDefaultEnglish: Bool
    public let supportsRecognitionBias: Bool

    public init(
        id: String, kind: EngineKind, displayName: String, summary: String, languageCount: Int,
        approxDownloadBytes: Int64, systemManaged: Bool, isDefaultEnglish: Bool,
        supportsRecognitionBias: Bool
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.summary = summary
        self.languageCount = languageCount
        self.approxDownloadBytes = approxDownloadBytes
        self.systemManaged = systemManaged
        self.isDefaultEnglish = isDefaultEnglish
        self.supportsRecognitionBias = supportsRecognitionBias
    }
}

public enum SpeechModelCatalog {
    public static let all: [SpeechModelInfo] = [
        SpeechModelInfo(
            id: "parakeet-tdt-ctc-110m", kind: .parakeet, displayName: "Parakeet TDT-CTC 110M",
            summary: "Compact English model — fast, accurate, and small.",
            languageCount: 1, approxDownloadBytes: 440_000_000, systemManaged: false,
            isDefaultEnglish: true, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "parakeet", kind: .parakeet, displayName: "Parakeet TDT v3",
            summary: "Larger multilingual Parakeet; slightly stronger raw accuracy.",
            languageCount: 25, approxDownloadBytes: 1_800_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "whisper-small-en", kind: .whisper, displayName: "Whisper Small (English)",
            summary: "Compact English Whisper — smaller and faster than Turbo, lower accuracy.",
            languageCount: 1, approxDownloadBytes: 217_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "whisper", kind: .whisper, displayName: "Whisper Large v3 Turbo",
            summary: "Broad language coverage with strong accuracy.",
            languageCount: 99, approxDownloadBytes: 632_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "qwen3-asr-0.6b", kind: .qwen3asr, displayName: "Qwen3-ASR 0.6B",
            summary: "Compact multilingual model; the speed/accuracy sweet spot in our benchmarks.",
            languageCount: 52, approxDownloadBytes: 1_500_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "qwen3-asr-1.7b", kind: .qwen3asr, displayName: "Qwen3-ASR 1.7B",
            summary: "Largest multilingual model; top accuracy in our benchmarks.",
            languageCount: 52, approxDownloadBytes: 2_000_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "apple", kind: .apple, displayName: "Apple Speech",
            summary: "Native macOS transcription. No download, fastest startup.",
            languageCount: 20, approxDownloadBytes: 0, systemManaged: true,
            isDefaultEnglish: false, supportsRecognitionBias: true),
        SpeechModelInfo(
            id: "moonshine-base-en", kind: .moonshine, displayName: "Moonshine Base (English)",
            summary: "Lightweight English model; dictionary recovery available.",
            languageCount: 1, approxDownloadBytes: 141_000_000, systemManaged: false,
            isDefaultEnglish: false, supportsRecognitionBias: false),
    ]

    public static func entry(for id: String) -> SpeechModelInfo? {
        all.first { $0.id == id }
    }

    public static var defaultEnglishId: String {
        all.first(where: \.isDefaultEnglish)?.id ?? all[0].id
    }
}
