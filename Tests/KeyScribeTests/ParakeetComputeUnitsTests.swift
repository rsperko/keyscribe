import CoreML
import FluidAudio
import Testing
@testable import KeyScribeApp

struct ParakeetComputeUnitsTests {
    @Test func theFusedEncoderModelIsKeptOffTheNeuralEngine() {
        let configuration = ParakeetEngine.modelConfiguration(for: .tdtCtc110m)
        #expect(configuration?.computeUnits == .cpuAndGPU)
    }

    @Test func theOtherParakeetModelsKeepFluidAudiosDefaults() {
        #expect(ParakeetEngine.modelConfiguration(for: .v3) == nil)
        #expect(ParakeetEngine.modelConfiguration(for: .v2) == nil)
    }
}
