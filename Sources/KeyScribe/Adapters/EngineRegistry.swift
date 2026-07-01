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
    static let descriptors: [EngineDescriptor] = SpeechModelCatalog.all
        .filter { isAvailable($0.id) }
        .map { info in
            EngineDescriptor(info: info, make: { dir in construct(info.id, dir) })
        }

    // Catalog entries available on this OS — the single list the model pickers (first run, Settings)
    // derive from, so an engine that cannot run here is never offered, not just unconstructable.
    static var availableCatalog: [SpeechModelInfo] {
        SpeechModelCatalog.all.filter { isAvailable($0.id) }
    }

    // The Apple Speech engine is built on SpeechAnalyzer/DictationTranscriber, which exist only on
    // macOS 26+. On older systems it is absent from the catalog the UI and download path derive from.
    static func isAvailable(_ id: String) -> Bool {
        if id == "apple" {
            if #available(macOS 26, *) { return true } else { return false }
        }
        return true
    }

    // Every engine the app actually loads/transcribes/evicts (the provider's set, plus the dev
    // benchmark/commands-check) is wrapped in SerializedEngine, so concurrent load/evict across the
    // Settings download, first-run download, launch preload, self-test, and memory-pressure paths can
    // never data-race the SDK handle or tear it down under a live transcribe (engines-models.md §1.1,
    // §1.4). The unwrapped `engine(_:)` below stays for install-only queries, which touch no SDK state.
    static func makeAll(modelsDir: URL) -> [any SpeechEngine] {
        descriptors.map { SerializedEngine($0.make(modelsDir)) }
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
        case "whisper": return WhisperEngine(profile: .largeV3Turbo, modelsDir: modelsDir)
        case "whisper-small-en": return WhisperEngine(profile: .smallEnglish, modelsDir: modelsDir)
        case "apple":
            if #available(macOS 26, *) { return AppleEngine() }
            fatalError("EngineRegistry: Apple Speech engine requires macOS 26")
        case "qwen3-asr-0.6b": return Qwen3ASREngine(profile: .small, modelsDir: modelsDir)
        case "qwen3-asr-1.7b": return Qwen3ASREngine(profile: .large, modelsDir: modelsDir)
        case "moonshine-base-en": return MoonshineEngine(modelsDir: modelsDir)
        default: fatalError("EngineRegistry: no constructor for engine id '\(id)'")
        }
    }
}
