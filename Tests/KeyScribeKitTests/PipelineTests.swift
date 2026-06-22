import Testing
@testable import KeyScribeKit

private struct AppendStage: PipelineStage {
    let position: StagePosition
    let order: Int
    let mark: String
    func run(_ context: inout PipelineContext) { context.text += mark }
}

struct PipelineTests {
    @Test func runsStagesInCanonicalPositionOrder() {
        // Added out of order; must run preSTT → postSTTText → insertion regardless.
        let p = Pipeline([
            AppendStage(position: .insertion, order: 0, mark: "C"),
            AppendStage(position: .preSTT, order: 0, mark: "A"),
            AppendStage(position: .postSTTText, order: 0, mark: "B"),
        ])
        #expect(p.run("") == "ABC")
    }

    @Test func orderIndexBreaksTiesWithinPosition() {
        let p = Pipeline([
            AppendStage(position: .postSTTText, order: 2, mark: "Z"),
            AppendStage(position: .postSTTText, order: 1, mark: "Y"),
            AppendStage(position: .postSTTText, order: 0, mark: "X"),
        ])
        #expect(p.run("") == "XYZ")
    }

    @Test func liveEditsRunBeforeReplacements() {
        // Canonical: within postSTTText, live edits (lower order) precede replacements.
        #expect(StagePosition.postSTTText < StagePosition.postSTTMark)
        #expect(StageOrder.liveEdits < StageOrder.replacements)
    }

    @Test func emptyPipelineIsIdentity() {
        #expect(Pipeline([]).run("hello") == "hello")
    }

    @Test func positionsAreCanonicallyOrdered() {
        #expect(StagePosition.preSTT < StagePosition.postSTTText)
        #expect(StagePosition.postSTTText < StagePosition.postSTTMark)
        #expect(StagePosition.postSTTMark < StagePosition.restore)
        #expect(StagePosition.restore < StagePosition.insertion)
    }
}
