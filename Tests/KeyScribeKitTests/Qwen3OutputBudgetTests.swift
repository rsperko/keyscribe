import Testing
@testable import KeyScribeKit

struct Qwen3OutputBudgetTests {
    @Test func aShortClipKeepsTheDecoderDefault() {
        #expect(Qwen3OutputBudget.maxTokens(audioSeconds: 0) == 448)
        #expect(Qwen3OutputBudget.maxTokens(audioSeconds: 30) == 448)
    }

    @Test(arguments: [60.0, 150, 300, 900, 1200])
    func aLongTakeHasRoomForFastDenseSpeech(_ seconds: Double) {
        #expect(Qwen3OutputBudget.maxTokens(audioSeconds: seconds) >= Int(seconds * 6))
    }

    @Test func theBudgetGrowsWithTheTake() {
        #expect(Qwen3OutputBudget.maxTokens(audioSeconds: 600) > Qwen3OutputBudget.maxTokens(audioSeconds: 300))
    }

    @Test func audioPastTheModelsInputCeilingIsRefused() {
        #expect(Qwen3OutputBudget.accepts(audioSeconds: 1200))
        #expect(!Qwen3OutputBudget.accepts(audioSeconds: 1200.5))
    }
}
