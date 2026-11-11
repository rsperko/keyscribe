import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct WarmupClipChoiceTests {
    private static let measured: [String: Bool] = [
        "whisper": true,
        "whisper-small-en": true,
        "parakeet-tdt-ctc-110m": true,
        "parakeet-ultra": false,
        "parakeet": false,
        "parakeet-unified-en": false,
        "qwen3-asr-0.6b": false,
        "qwen3-asr-1.7b": false,
        "apple": false,
    ]

    @Test func onlyEnginesWhoseFirstInferenceIsSlowRunTheWarmupClip() {
        let dir = FileManager.default.temporaryDirectory
        for engine in EngineRegistry.makeAll(modelsDir: dir) {
            #expect(engine.benefitsFromWarmupClip == Self.measured[engine.id], "\(engine.id)")
        }
    }

    @Test func everyCatalogEngineHasAMeasuredWarmupChoice() {
        for model in EngineRegistry.availableCatalog {
            #expect(Self.measured[model.id] != nil, "\(model.id) needs --warmup-probe before it ships")
        }
    }
}
