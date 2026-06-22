import Foundation
import KeyScribeKit

// Single source of truth pairing each catalog entry with how to construct its adapter. The provider,
// the download path, install reconcile/delete, and the benchmark all build their engine lists from
// here, so adding an engine is one descriptor + its catalog entry — never six scattered edits.
struct EngineDescriptor {
    let info: SpeechModelInfo
    let make: @Sendable (URL) -> any SpeechEngine
}

enum EngineRegistry {
    static let descriptors: [EngineDescriptor] = SpeechModelCatalog.all.map { info in
        EngineDescriptor(info: info, make: { dir in construct(info.id, dir) })
    }

    static func makeAll(modelsDir: URL) -> [any SpeechEngine] {
        descriptors.map { $0.make(modelsDir) }
    }

    static func engine(_ id: String, modelsDir: URL) -> (any SpeechEngine)? {
        descriptors.first { $0.info.id == id }?.make(modelsDir)
    }

    // The one place per-engine construction lives: maps a catalog id to its adapter. Keyed off the
    // catalog (the metadata SSOT) so ids can't drift.
    private static func construct(_ id: String, _ modelsDir: URL) -> any SpeechEngine {
        switch id {
        case "parakeet": return ParakeetEngine(profile: .tdtV3, modelsDir: modelsDir)
        case "parakeet-tdt-ctc-110m": return ParakeetEngine(profile: .tdtCtc110m, modelsDir: modelsDir)
        case "whisper": return WhisperEngine(modelsDir: modelsDir)
        case "apple": return AppleEngine()
        case "qwen3-asr-0.6b": return Qwen3ASREngine(profile: .small, modelsDir: modelsDir)
        case "qwen3-asr-1.7b": return Qwen3ASREngine(profile: .large, modelsDir: modelsDir)
        case "moonshine-base-en": return MoonshineEngine(modelsDir: modelsDir)
        default: fatalError("EngineRegistry: no constructor for engine id '\(id)'")
        }
    }
}
