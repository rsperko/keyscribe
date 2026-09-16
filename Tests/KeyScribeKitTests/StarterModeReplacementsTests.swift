import Testing
@testable import KeyScribeKit

// Run through the real stage (not just parsed) so a seeded pattern that fails ReplacementSafety or
// RegexCache — and would otherwise be silently dropped — fails these tests instead.
private func rules(_ id: String) -> [ReplacementRule] {
    ModeStore.starterModes().first { $0.id == id }?.replacements.toRules() ?? []
}

private func run(_ rules: [ReplacementRule], on text: String) -> String {
    var ctx = PipelineContext(text: text)
    ReplacementsStage(rules: rules).apply(&ctx)
    return ctx.text
}

struct StarterModeReplacementsTests {
    @Test func markdownInsertCheckboxStartsATaskItemOnItsOwnLine() {
        let md = rules("markdown")
        #expect(run(md, on: "buy milk insert checkbox eggs") == "buy milk\n- [ ] eggs")
        #expect(run(md, on: "insert a checkbox buy milk") == "\n- [ ] buy milk")
    }

    @Test func markdownInsertCheckboxToleratesSTTVariants() {
        let md = rules("markdown")
        #expect(run(md, on: "buy milk, insert check box, eggs") == "buy milk\n- [ ] eggs")
        #expect(run(md, on: "Insert, checkbox. eggs") == "\n- [ ] eggs")
        #expect(run(md, on: "one insert checkbox milk insert checkbox eggs") == "one\n- [ ] milk\n- [ ] eggs")
    }

    @Test func markdownInsertHorizontalRuleKeepsAPeriodAndAbsorbsACommaOnTheLeft() {
        let md = rules("markdown")
        #expect(run(md, on: "section one. insert horizontal rule section two") == "section one.\n\n---\n\nsection two")
        #expect(run(md, on: "section one, insert a horizontal rule, section two") == "section one\n\n---\n\nsection two")
    }

    @Test func markdownBoldAndItalicPairsHugTheEnclosedWords() {
        let md = rules("markdown")
        #expect(run(md, on: "this is begin bold important end bold stuff") == "this is **important** stuff")
        #expect(run(md, on: "this is, begin bold, important, end bold, stuff") == "this is, **important** stuff")
        #expect(run(md, on: "a begin italic subtle end italic hint") == "a *subtle* hint")
    }

    @Test func markdownCodeBlockPairPutsFencesOnTheirOwnLines() {
        let md = rules("markdown")
        #expect(run(md, on: "begin code block let x equal one end code block")
            == "\n```\nlet x equal one\n```\n")
        #expect(run(md, on: "run this. begin code fence, make test, end code fence. then push")
            == "run this.\n```\nmake test\n```\nthen push")
    }

    @Test func markdownHasNoBareEndCodeRule() {
        let md = rules("markdown")
        #expect(run(md, on: "the front end code is messy") == "the front end code is messy")
        #expect(run(md, on: "at the end code review happens") == "at the end code review happens")
    }

    @Test func codeInsertTodoStartsACommentAcrossTodoSpellings() {
        let code = rules("code")
        #expect(run(code, on: "fix the parser insert todo handle unicode") == "fix the parser\n// TODO: handle unicode")
        #expect(run(code, on: "fix the parser insert a to do handle unicode") == "fix the parser\n// TODO: handle unicode")
        #expect(run(code, on: "fix the parser. Insert to-do, handle unicode") == "fix the parser.\n// TODO: handle unicode")
    }

    @Test func messageShrugEmojiIsInsertedVerbatim() {
        let msg = rules("message")
        #expect(run(msg, on: "i mean shrug emoji whatever") == #"i mean ¯\_(ツ)_/¯ whatever"#)
    }

    @Test func messageShrugEmojiAloneClampsToTheBareEmoticon() {
        var ctx = PipelineContext(text: "Shrug emoji.")
        ReplacementsStage(rules: rules("message")).apply(&ctx)
        #expect(ctx.bareReplacement?.text == #"¯\_(ツ)_/¯"#)
    }

    @Test func emailMySignOffAppendsTheSignatureStub() {
        let email = rules("email")
        #expect(run(email, on: "let me know if thursday works. my sign off")
            == "let me know if thursday works.\n\nBest,\nYour Name")
        #expect(run(email, on: "talk soon, my sign-off") == "talk soon\n\nBest,\nYour Name")
    }

    @Test func markdownPromptDelegatesSpokenMarkersToTheSeededRules() {
        let prompt = ModeStore.starterModes().first { $0.id == "markdown" }?.aiRewrite?.prompt ?? ""
        #expect(prompt.contains("may already contain Markdown syntax"))
        #expect(!prompt.contains("spoken markers"))
        #expect(!prompt.contains("back tick"))
    }

    @Test func emailPromptKeepsAnExistingClosing() {
        let email = ModeStore.starterModes().first { $0.id == "email" }
        #expect(email?.aiRewrite?.prompt.contains("already contains a closing or signature") == true)
    }

    @Test func seededRulesRoundTripThroughTOML() throws {
        for mode in ModeStore.starterModes() where !mode.replacements.rules.isEmpty {
            let decoded = try ModeStore.decode(from: ModeStore.encode(mode), id: mode.id)
            #expect(decoded.replacements == mode.replacements)
        }
    }

    @Test func onlyTheFourExampleCarriersSeedRules() {
        let seeded = ModeStore.starterModes().filter { !$0.replacements.rules.isEmpty }
        #expect(Set(seeded.map(\.id)) == ["markdown", "code", "message", "email"])
        #expect(seeded.allSatisfy { $0.replacements.includeGlobal })
    }
}
