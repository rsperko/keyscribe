@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct AgentPhrasesTests {
    private func unquoted(_ phrase: String) -> String {
        String(phrase.dropFirst().dropLast()).trimmingCharacters(in: .punctuationCharacters)
    }

    private func phrases(name: String, readsReplies: Bool) -> [String] {
        AgentPhrasesReference.examples(name: name, readsReplies: readsReplies).map { unquoted($0.phrase) }
    }

    @Test func tellingANameSendsTheInstructionThere() {
        let said = phrases(name: "backend", readsReplies: false)[0]
        #expect(VoiceCommandGrammar.parse(said) == nil)
        #expect(AgentRename.request(in: said) == nil)
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .name("backend", body: "run the unit tests"))
    }

    @Test func noPhraseSelectsOrFollowsAConversation() {
        for said in phrases(name: "backend", readsReplies: true) {
            #expect(!said.hasPrefix("select") && !said.hasPrefix("choose") && !said.hasPrefix("follow"))
        }
    }

    @Test func openingANameShowsItWithoutAMessage() {
        let said = phrases(name: "backend", readsReplies: false)[1]
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .open(.name("backend", body: "")))
    }

    @Test func theStatusChecksAreAnsweredWithoutSendingAnything() {
        let said = phrases(name: "backend", readsReplies: false)
        #expect(AgentStatusQuery.parse(said[2], names: ["backend"]) == .check(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse(said[3], names: ["backend"]) == .all)
    }

    @Test func goBackCancelAndRepeatAreTheBuiltInCommands() {
        let said = phrases(name: "backend", readsReplies: false)
        #expect(VoiceCommandGrammar.parse(said[4]) == .goBack)
        #expect(VoiceCommandGrammar.parse(said[5]) == .cancel)
        #expect(said.count == 6)
        let reading = phrases(name: "backend", readsReplies: true)
        #expect(reading.count == 8)
        #expect(VoiceCommandGrammar.parse(reading[4]) == .repeatSummary)
        #expect(VoiceCommandGrammar.parse(reading[5]) == .keepReply)
    }

    @Test func withoutNamesTheExamplesUseTheConversationNumber() {
        let said = phrases(name: "conversation two", readsReplies: false)
        #expect(AgentAddress.parse(said[0], names: [], namesKnown: false) == .row(2, body: "run the unit tests"))
        #expect(AgentAddress.parse(said[1], names: [], namesKnown: false) == .open(.row(2, body: "")))
        #expect(AgentStatusQuery.parse(said[2], names: [], namesKnown: false) == .check(.row(2, body: "")))
    }

    @Test func renamingNamesTheConversationInstructionsGoTo() {
        #expect(AgentRename.parse(unquoted(AgentPhrasesReference.renameExample)) == .rename("API"))
    }
}
