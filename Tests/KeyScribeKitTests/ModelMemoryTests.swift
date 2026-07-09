import Testing
@testable import KeyScribeKit

struct ModelMemoryTests {
    private let gb: Int64 = 1_000_000_000
    private func ram(_ g: Double) -> UInt64 { UInt64(g * 1_000_000_000) }

    @Test func biasAddsToPeakOnlyWhenOn() {
        #expect(ModelMemory.peakBytes(baseBytes: 550 * 1_000_000, biasBytes: 600 * 1_000_000, biasOn: false) == 550_000_000)
        #expect(ModelMemory.peakBytes(baseBytes: 550 * 1_000_000, biasBytes: 600 * 1_000_000, biasOn: true) == 1_150_000_000)
    }

    @Test func heavyModelIsComfortableOnLargeRamHeavyOnSmall() {
        let whisperTurbo: Int64 = 3_700_000_000
        #expect(ModelMemory.verdict(peakBytes: whisperTurbo, physicalBytes: ram(16)) == .comfortable)
        #expect(ModelMemory.verdict(peakBytes: whisperTurbo, physicalBytes: ram(8)) == .heavy)
    }

    @Test func lightModelIsComfortableEvenOnSmallRam() {
        let parakeetWithBias: Int64 = 1_150_000_000
        #expect(ModelMemory.verdict(peakBytes: parakeetWithBias, physicalBytes: ram(8)) == .comfortable)
    }

    @Test func turningBiasOnCanFlipTheVerdict() {
        // A model that is comfortable alone but heavy once its companion loads, on a small machine.
        let base: Int64 = 2_800_000_000, bias: Int64 = 900_000_000
        let off = ModelMemory.peakBytes(baseBytes: base, biasBytes: bias, biasOn: false)
        let on = ModelMemory.peakBytes(baseBytes: base, biasBytes: bias, biasOn: true)
        #expect(ModelMemory.verdict(peakBytes: off, physicalBytes: ram(8)) == .comfortable)
        #expect(ModelMemory.verdict(peakBytes: on, physicalBytes: ram(8)) == .heavy)
    }

    @Test func unknownFootprintOrRamIsComfortable() {
        #expect(ModelMemory.verdict(peakBytes: 0, physicalBytes: ram(8)) == .comfortable)
        #expect(ModelMemory.verdict(peakBytes: gb, physicalBytes: 0) == .comfortable)
    }
}
