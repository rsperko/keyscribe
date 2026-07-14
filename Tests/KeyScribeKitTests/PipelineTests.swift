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
    func applied(_ text: String) -> String { forward(text).text }
}

struct PipelineTests {
    @Test func runsStagesInCanonicalPositionOrder() {
        // Stages added out of declaration order; must still run verbatimMark → postSTTText → postSTTMark.
        let p = Pipeline([
            AppendStage(position: .postSTTMark, order: 0, mark: "C"),
            AppendStage(position: .verbatimMark, order: 0, mark: "A"),
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
        #expect(StagePosition.verbatimMark < StagePosition.postSTTText)
        #expect(StagePosition.postSTTText < StagePosition.postSTTMark)
    }

    // forward applies in (position, order); reverse runs post in STRICT REVERSE, so nested wraps
    // unwind LIFO and the text returns to its original.
    @Test func reverseRunsPostInStrictReverse() {
        let p = Pipeline([
            WrapStage(position: .verbatimMark, order: 0, tag: "outer"),
            WrapStage(position: .postSTTMark, order: 0, tag: "inner"),
        ])
        let payload = p.forward("x")
        #expect(payload.text == "(inner (outer x))")   // outer applies first (innermost), inner wraps it
        #expect(p.restore(payload.text) == "x")        // inner.post then outer.post — LIFO
    }

    // A one-way stage's default post is a no-op, so reverse leaves its forward effect intact.
    @Test func oneWayStagePostIsNoOp() {
        let p = Pipeline([AppendStage(position: .postSTTText, order: 0, mark: "!")])
        let payload = p.forward("hi")
        #expect(p.restore(payload.text) == "hi!")
    }
}
