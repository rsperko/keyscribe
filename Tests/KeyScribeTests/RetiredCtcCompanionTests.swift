import Foundation
import Testing
@testable import KeyScribe

struct RetiredCtcCompanionTests {
    // Must target only the orphaned 0.6B spotter model, never the 110M CTC head — FluidAudio's
    // tdt-ctc-110m load re-downloads parakeet-ctc-110m-coreml on demand, so deleting it would churn a
    // re-download every launch.
    @Test func reclaimsOnlyThe06bSpotterCompanion() {
        let names = ModelInstallStore.retiredCtcCompanionDirNames
        #expect(names.contains("parakeet-ctc-0.6b-coreml"))
        #expect(!names.contains("parakeet-ctc-110m-coreml"))
    }

    // Counted in the footprint and removed with the model, even though recognition bias never uses it.
    @Test func the110mEngineOwnsItsCtcHeadDir() {
        let engine = ParakeetEngine(profile: .tdtCtc110m, modelsDir: URL(fileURLWithPath: "/tmp"))
        #expect(engine.installDirNames.contains("parakeet-tdt-ctc-110m"))
        #expect(engine.installDirNames.contains("parakeet-ctc-110m-coreml"))
    }

    @Test func v3EngineOwnsOnlyItsTdtBundle() {
        let engine = ParakeetEngine(profile: .tdtV3, modelsDir: URL(fileURLWithPath: "/tmp"))
        #expect(engine.installDirNames == ["parakeet-tdt-0.6b-v3"])
    }
}
