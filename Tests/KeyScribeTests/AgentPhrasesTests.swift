@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct AgentPhrasesTests {
    private func unquoted(_ phrase: String) -> String {
        String(phrase.dropFirst().dropLast()).trimmingCharacters(in: .punctuationCharacters)
    }

    private func phrases(readsReplies: Bool) -> [String] {
        AgentPhrasesReference.phrases(readsReplies: readsReplies).map(\.said)
    }

    @Test func tellingANameSendsTheInstructionThere() {
        let said = phrases(readsReplies: false)[0]
        #expect(VoiceCommandGrammar.parse(said) == nil)
        #expect(AgentRename.request(in: said) == nil)
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .name("backend", body: "run the unit tests"))
    }

    @Test func noPhraseSelectsOrFollowsAConversation() {
        for said in phrases(readsReplies: true) {
            #expect(!said.hasPrefix("select") && !said.hasPrefix("choose") && !said.hasPrefix("follow"))
        }
    }

    private func phrase(_ prefix: String, readsReplies: Bool = false) throws -> String {
        try #require(phrases(readsReplies: readsReplies).first { $0.hasPrefix(prefix) })
    }

    @Test func openingANameShowsItWithoutAMessage() throws {
        let said = try phrase("open ")
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .open(.name("backend", body: "")))
    }

    @Test func theStatusChecksAreAnsweredWithoutSendingAnything() throws {
        #expect(AgentStatusQuery.parse(try phrase("check on B"), names: ["backend"]) == .check(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse(try phrase("check on all"), names: ["backend"]) == .all)
    }

    @Test func askingAQuestionSendsIt() throws {
        #expect(AgentAddress.parse(try phrase("ask "), names: ["backend"]) == .name("backend", body: "what changed"))
    }

    @Test func theNumberedExampleUsesTheListShownWhileRecording() throws {
        let said = try phrase("tell conversation")
        #expect(AgentAddress.parse(said.replacingOccurrences(of: "\u{2026}", with: "run the tests"), names: ["backend"]) == .row(1, body: "run the tests"))
    }

    @Test func renamingIsAPhraseAndRenamesTheConversationInFront() throws {
        let said = try phrase("rename ")
        #expect(AgentRename.parse(said.replacingOccurrences(of: "\u{2026}", with: AgentPhrasesReference.exampleName)) == .rename(AgentPhrasesReference.exampleName))
    }

    @Test func goBackCancelAndRepeatAreTheBuiltInCommands() {
        let said = phrases(readsReplies: false)
        #expect(said.suffix(2).map { VoiceCommandGrammar.parse($0) } == [.goBack, .cancel])
        #expect(!said.contains(VoiceCommandGrammar.repeatSummary[0]))
        let reading = phrases(readsReplies: true)
        #expect(reading.count == said.count + 3)
        let replies = reading.filter { !said.contains($0) }
        #expect(replies.map { VoiceCommandGrammar.parse($0) } == [.repeatSummary, .readReply, .keepReply])
    }

    @Test func withoutNamesTheExamplesUseTheConversationNumber() {
        let said = SpokenHelp.agentPhrases(name: "conversation two", readsReplies: false).map(\.said)
        #expect(AgentAddress.parse(said[0], names: [], namesKnown: false) == .row(2, body: "run the unit tests"))
        #expect(AgentAddress.parse("open conversation two", names: [], namesKnown: false) == .open(.row(2, body: "")))
        #expect(said.contains("open conversation two"))
        #expect(said.contains("check on conversation two"))
        #expect(AgentStatusQuery.parse("check on conversation two", names: [], namesKnown: false) == .check(.row(2, body: "")))
    }

    @Test func theRoutingExampleIsTheFirstPhraseAndSendsOnlyThatInstruction() {
        let said = phrases(readsReplies: false)[0]
        #expect(AgentPhrasesReference.routingExample.hasPrefix("\u{201C}\(said)\u{201D}"))
        #expect(AgentAddress.parse(said, names: ["backend"]) == .name("backend", body: "run the unit tests"))
    }
}
