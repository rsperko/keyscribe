import Testing
@testable import KeyScribeKit

struct EngineSelectionTests {
    private let runnable = ["parakeet", "whisper", "qwen3-asr-0.6b"]

    @Test func noRequestRunsEveryRunnableEngine() {
        #expect(EngineSelection.resolve(requested: nil, runnable: runnable) == .ok(runnable))
    }

    @Test func aRequestRunsThoseEnginesInRunnableOrder() {
        #expect(EngineSelection.resolve(requested: ["qwen3-asr-0.6b", "parakeet"], runnable: runnable)
            == .ok(["parakeet", "qwen3-asr-0.6b"]))
    }

    @Test func anyRequestedEngineThatCannotRunIsAnInvocationError() {
        #expect(EngineSelection.resolve(requested: ["parakeet", "no-such", "missing"], runnable: runnable)
            == .invalid(["missing", "no-such"]))
    }

    @Test func listStatePrefersUnavailableOverEveryInstallState() {
        #expect(EngineListState.of(systemManaged: true, installed: false, unavailable: true) == .unavailable)
        #expect(EngineListState.of(systemManaged: false, installed: true, unavailable: true) == .unavailable)
        #expect(EngineListState.of(systemManaged: true, installed: false, unavailable: false) == .system)
        #expect(EngineListState.of(systemManaged: false, installed: true, unavailable: false) == .installed)
        #expect(EngineListState.of(systemManaged: false, installed: false, unavailable: false) == .missing)
    }
}
