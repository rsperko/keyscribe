import Testing
@testable import KeyScribeKit

private struct AppendStage: PipelineStage {
    let position: StagePosition
    let order: Int
    let mark: String
    func apply(_ context: inout PipelineContext) { context.text += mark }
}

// Brackets text in apply, strips it in post — proves post runs in strict reverse of apply.
private struct WrapStage: PipelineStage {
    let position: StagePosition
    let order: Int
    let tag: String
    func apply(_ context: inout PipelineContext) { context.text = "(\(tag) " + context.text + ")" }
    func post(_ context: inout PipelineContext) {
        context.text = context.text
            .replacingOccurrences(of: "(\(tag) ", with: "")
            .replacingOccurrences(of: ")", with: "")
    }
}

private extension Pipeline {
    func applied(_ text: String) -> String {
        var ctx = PipelineContext(text: text)
        forward(&ctx)
        return ctx.text
    }
}

struct PipelineTests {
    @Test func runsStagesInCanonicalPositionOrder() {
        // Added out of order; must run preSTT → postSTTText → insertion regardless.
        let p = Pipeline([
            AppendStage(position: .insertion, order: 0, mark: "C"),
            AppendStage(position: .preSTT, order: 0, mark: "A"),
            AppendStage(position: .postSTTText, order: 0, mark: "B"),
        ])
        #expect(p.applied("") == "ABC")
    }

    @Test func orderIndexBreaksTiesWithinPosition() {
        let p = Pipeline([
            AppendStage(position: .postSTTText, order: 2, mark: "Z"),
            AppendStage(position: .postSTTText, order: 1, mark: "Y"),
            AppendStage(position: .postSTTText, order: 0, mark: "X"),
        ])
        #expect(p.applied("") == "XYZ")
    }

    @Test func liveEditsRunBeforeReplacements() {
        // Canonical: within postSTTText, live edits (lower order) precede replacements.
        #expect(StagePosition.postSTTText < StagePosition.postSTTMark)
        #expect(StageOrder.liveEdits < StageOrder.replacements)
    }

    @Test func emptyPipelineIsIdentity() {
        #expect(Pipeline([]).applied("hello") == "hello")
    }

    @Test func positionsAreCanonicallyOrdered() {
        #expect(StagePosition.preSTT < StagePosition.verbatimMark)
        #expect(StagePosition.verbatimMark < StagePosition.postSTTText)
        #expect(StagePosition.postSTTText < StagePosition.postSTTMark)
        #expect(StagePosition.postSTTMark < StagePosition.restore)
        #expect(StagePosition.restore < StagePosition.insertion)
    }

    // forward applies in (position, order); reverse runs post in STRICT REVERSE, so nested wraps
    // unwind LIFO and the text returns to its original.
    @Test func reverseRunsPostInStrictReverse() {
        let p = Pipeline([
            WrapStage(position: .verbatimMark, order: 0, tag: "outer"),
            WrapStage(position: .postSTTMark, order: 0, tag: "inner"),
        ])
        var ctx = PipelineContext(text: "x")
        p.forward(&ctx)
        #expect(ctx.text == "(inner (outer x))")   // outer applies first (innermost), inner wraps it
        p.reverse(&ctx)
        #expect(ctx.text == "x")                    // inner.post then outer.post — LIFO
    }

    // A one-way stage's default post is a no-op, so reverse leaves its forward effect intact.
    @Test func oneWayStagePostIsNoOp() {
        let p = Pipeline([AppendStage(position: .postSTTText, order: 0, mark: "!")])
        var ctx = PipelineContext(text: "hi")
        p.forward(&ctx); p.reverse(&ctx)
        #expect(ctx.text == "hi!")
    }
}
