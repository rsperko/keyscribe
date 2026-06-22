import Testing
@testable import KeyScribeKit

private func sym(_ s: String) -> String { SpokenSymbols.apply(s) }

struct SpokenSymbolsTests {
    @Test func expandsCommonSymbols() {
        #expect(sym("open paren bar close paren") == "( bar )")
        #expect(sym("foo backslash bar") == "foo \\ bar")
        #expect(sym("dollar sign home") == "$ home")
    }

    @Test func longestPhraseWins() {
        #expect(sym("open angle bracket") == "<")
    }

    @Test func caseInsensitive() {
        #expect(sym("Open Paren") == "(")
    }

    @Test func leavesNonSymbolsAlone() {
        #expect(sym("just normal words") == "just normal words")
    }

    @Test func stageRunsAtSymbolsOrder() {
        let stage = SymbolsStage()
        #expect(stage.position == .postSTTText)
        #expect(stage.order == StageOrder.spokenSymbols)
        var ctx = PipelineContext(text: "x equals sign y")
        stage.run(&ctx)
        #expect(ctx.text == "x = y")
    }
}
