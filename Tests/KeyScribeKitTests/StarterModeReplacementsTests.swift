import Testing
@testable import KeyScribeKit

// The starter modes seed worked replacement examples — each teaches one technique (boundary-hugging
// regex, `\n` output, STT-variance alternation, verbatim literal, personalizable stub) behind a
// deliberate trigger phrase that plain prose can't fire. Verified through the real stage so a pattern
// that fails ReplacementSafety or RegexCache (silently dropped) fails these tests.
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

    // STT renders the phrase as "check box"/"checkbox" and hangs pause commas on the operator; the
    // seeded pattern absorbs both, like the live-edit insert commands do.
    @Test func markdownInsertCheckboxToleratesSTTVariants() {
        let md = rules("markdown")
        #expect(run(md, on: "buy milk, insert check box, eggs") == "buy milk\n- [ ] eggs")
        #expect(run(md, on: "Insert, checkbox. eggs") == "\n- [ ] eggs")
        #expect(run(md, on: "one insert checkbox milk insert checkbox eggs") == "one\n- [ ] milk\n- [ ] eggs")
    }

    // A preceding sentence period is dictated content and survives; a pause comma is absorbed.
    @Test func markdownInsertHorizontalRuleKeepsAPeriodAndAbsorbsACommaOnTheLeft() {
        let md = rules("markdown")
        #expect(run(md, on: "section one. insert horizontal rule section two") == "section one.\n\n---\n\nsection two")
        #expect(run(md, on: "section one, insert a horizontal rule, section two") == "section one\n\n---\n\nsection two")
    }

    // The open marker hugs the following word, the close marker hugs the preceding one — the smart-quote
    // recipe from docs/tips.md, seeded.
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

    // "front end code is messy" must stay prose — there is deliberately NO bare "begin/end code" pair
    // (only "code block"/"code fence"); inline code is the rewrite prompt's judgment call.
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

    // Spoken alone, the shrug is a whole-utterance replacement — inserted bare, skipping the rewrite.
    @Test func messageShrugEmojiAloneClampsToTheBareEmoticon() {
        var ctx = PipelineContext(text: "Shrug emoji.")
        ReplacementsStage(rules: rules("message")).apply(&ctx)
        #expect(ctx.bareReplacement == #"¯\_(ツ)_/¯"#)
    }

    // The stub is deliberately a placeholder — saying the phrase once shows the user exactly what to
    // personalize in the mode's replacements.
    @Test func emailMySignOffAppendsTheSignatureStub() {
        let email = rules("email")
        #expect(run(email, on: "let me know if thursday works. my sign off")
            == "let me know if thursday works.\n\nBest,\nYour Name")
        #expect(run(email, on: "talk soon, my sign-off") == "talk soon\n\nBest,\nYour Name")
    }

    // The marker vocabulary moved from prompt instructions to seeded rules: the prompt now only has to
    // preserve Markdown the rules already emitted, not interpret spoken markers itself.
    @Test func markdownPromptDelegatesSpokenMarkersToTheSeededRules() {
        let prompt = ModeStore.starterModes().first { $0.id == "markdown" }?.aiRewrite?.prompt ?? ""
        #expect(prompt.contains("may already contain Markdown syntax"))
        #expect(!prompt.contains("spoken markers"))
        #expect(!prompt.contains("back tick"))
    }

    // The Email prompt bans model-invented signatures, so it must explicitly keep one the dictated
    // text already carries — otherwise the rewrite strips the stub the rule just inserted.
    @Test func emailPromptKeepsAnExistingClosing() {
        let email = ModeStore.starterModes().first { $0.id == "email" }
        #expect(email?.aiRewrite?.prompt.contains("already contains a closing or signature") == true)
    }

    // The `\n`-bearing heard/replace strings must survive the TOML round trip a seed write/load takes.
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
