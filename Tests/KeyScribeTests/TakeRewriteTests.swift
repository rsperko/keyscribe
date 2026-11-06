import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct TakeRewriteTests {
    private struct Model: LLMClient {
        let reply: String?
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            guard let reply else { throw URLError(.cannotConnectToHost) }
            return reply
        }
    }

    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private let connection = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")

    private var mode: Mode {
        var mode = Mode(id: "m", name: "Notes")
        mode.aiRewrite = .init(connection: "c", prompt: "Rewrite it.", context: .init())
        return mode
    }

    private func run(
        _ reply: String?, spy: HUDSpy = HUDSpy(), checkpoints: inout [TakeRewrite.Checkpoint],
        cancelWhileBuilding: Bool = false
    ) async -> TakeRewrite.Result {
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(connections: [connection]), fragments: [:])
        let pipeline = TakeStages.dictation(
            text: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: []), clipboard: nil, redaction: false)
        let take = TakeText("hello world", pipeline: pipeline, trimsTrailingPunctuation: false)
        let rewriter = TakeRewrite(client: Model(reply: reply), permits: { _ in true }, hud: HUDChannel(hud: spy))
        var points: [TakeRewrite.Checkpoint] = []
        let mode = mode
        let connection = connection
        let result = await rewriter.rewrite(
            take, localText: take.localText, mode: mode, connection: connection,
            request: {
                if cancelWhileBuilding { withUnsafeCurrentTask { $0?.cancel() } }
                return await RewriteRequestBuilder(
                    mode: mode, content: take.payload.text, instruction: "", issuedTokens: [],
                    capturedBundleId: nil, capturedPid: nil, plan: plan, connection: connection).build()
            },
            checkpoint: { points.append($0) })
        checkpoints = points
        return result
    }

    @Test func aRewriteThatPassesTheGateIsTheText() async {
        let spy = HUDSpy()
        var points: [TakeRewrite.Checkpoint] = []
        let result = await run("Hello, world.", spy: spy, checkpoints: &points)
        #expect(result.ok)
        #expect(result.text == "Hello, world.")
        #expect(!result.details.fellBack)
        #expect(result.finished?.modelOutput == "Hello, world.")
        #expect(points.map(\.localText) == ["hello world"])
        #expect(spy.states.contains { if case .rewriting = $0 { true } else { false } })
    }

    @Test func aFailedRewriteFallsBackToTheLocalText() async {
        var points: [TakeRewrite.Checkpoint] = []
        let result = await run(nil, checkpoints: &points)
        #expect(!result.ok)
        #expect(result.text == "hello world")
        #expect(result.details.fellBack)
        #expect(result.finished != nil)
        #expect(result.finished?.modelOutput == nil)
    }

    @Test func aTakeCancelledWhileTheRequestBuildsNeverShowsTheRewriteOrOffersTheEscapeHatch() async {
        let spy = HUDSpy()
        var points: [TakeRewrite.Checkpoint] = []
        let result = await Task { @MainActor in
            await run("Hello, world.", spy: spy, checkpoints: &points, cancelWhileBuilding: true)
        }.value
        #expect(!result.ok)
        #expect(result.text == "hello world")
        #expect(points.isEmpty)
        #expect(spy.states.isEmpty)
        #expect(result.finished == nil)
    }
}
