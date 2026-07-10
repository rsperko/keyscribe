import Testing
@testable import KeyScribeKit

struct ModelMemoryTests {
    private let gb: Int64 = 1_000_000_000
    private func ram(_ g: Double) -> UInt64 { UInt64(g * 1_000_000_000) }

    @Test func heavyModelIsComfortableOnLargeRamHeavyOnSmall() {
        let whisperTurbo: Int64 = 3_700_000_000
        #expect(ModelMemory.verdict(peakBytes: whisperTurbo, physicalBytes: ram(16)) == .comfortable)
        #expect(ModelMemory.verdict(peakBytes: whisperTurbo, physicalBytes: ram(8)) == .heavy)
    }

    @Test func lightModelIsComfortableEvenOnSmallRam() {
        let parakeetBase: Int64 = 550_000_000
        #expect(ModelMemory.verdict(peakBytes: parakeetBase, physicalBytes: ram(8)) == .comfortable)
    }

    @Test func unknownFootprintOrRamIsComfortable() {
        #expect(ModelMemory.verdict(peakBytes: 0, physicalBytes: ram(8)) == .comfortable)
        #expect(ModelMemory.verdict(peakBytes: gb, physicalBytes: 0) == .comfortable)
    }
}
