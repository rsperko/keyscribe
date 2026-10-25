import Foundation
import Testing
@testable import KeyScribeKit

struct ScriptReportTests {
    private func collect(_ chunks: String...) -> ScriptReport {
        var collector = ScriptReport.Collector()
        for chunk in chunks { collector.append(Data(chunk.utf8)) }
        return collector.finish()
    }

    @Test func plainOutputReportsNothing() {
        #expect(collect("Switched\nall good\n") == ScriptReport())
    }

    @Test func aDoneLineIsTheMessage() {
        #expect(collect("working\n::done::Switched to Inbox\n").message == .init(level: .done, text: "Switched to Inbox"))
    }

    @Test func anInfoLineIsAnInformationalMessage() {
        #expect(collect("::info::Nothing waiting\n").message == .init(level: .info, text: "Nothing waiting"))
    }

    @Test func theLastMessageWins() {
        #expect(collect("::info::first\n::done::second\n").message == .init(level: .done, text: "second"))
    }

    @Test func aFinalLineWithoutANewlineCounts() {
        #expect(collect("::done::Opened").message == .init(level: .done, text: "Opened"))
    }

    @Test func linesSplitAcrossChunksAreJoined() {
        #expect(collect("::do", "ne::Opened #gen", "eral\n").message == .init(level: .done, text: "Opened #general"))
    }

    @Test func anEmptyMessageIsIgnored() {
        #expect(collect("::done::Opened\n::done::   \n").message == .init(level: .done, text: "Opened"))
    }

    @Test func aLongMessageIsShortened() throws {
        let text = String(repeating: "x", count: ScriptReport.textLimit + 50)
        let message = try #require(collect("::done::\(text)\n").message)
        #expect(message.text == String(repeating: "x", count: ScriptReport.textLimit) + "\u{2026}")
    }

    @Test func aMarkerMustStartTheLine() {
        #expect(collect("note ::done::not a report\n") == ScriptReport())
    }

    @Test func choicesKeepTheirOrderAndSplitValueFromLabel() {
        #expect(collect("::choice::C123\t#general\n::choice::C456\t#random\n").options == [
            .init(value: "C123", label: "#general"), .init(value: "C456", label: "#random"),
        ])
    }

    @Test func aChoiceWithoutATabUsesTheTextAsBoth() {
        #expect(collect("::choice::Inbox\n").options == [.init(value: "Inbox", label: "Inbox")])
    }

    @Test func aRepeatedChoiceValueIsListedOnce() {
        #expect(collect("::choice::a\tFirst\n::choice::a\tAgain\n").options == [.init(value: "a", label: "First")])
    }

    @Test func aChoiceWithNoLabelIsSkipped() {
        #expect(collect("::choice::a\t \n::choice::\n").options.isEmpty)
    }

    @Test func reportLinesSurviveVerboseOutput() {
        let noise = String(repeating: "progress line\n", count: 20_000)
        let report = collect("::choice::a\tA\n", noise, "::choice::b\tB\n", noise, "::done::finished\n")
        #expect(report.options.map(\.value) == ["a", "b"])
        #expect(report.message?.text == "finished")
    }

    @Test func anEndlessLineIsDropped() {
        let huge = String(repeating: "x", count: ScriptReport.Collector.lineLimit * 2)
        #expect(collect("::done::", huge, "\n::info::after\n").message == .init(level: .info, text: "after"))
    }

    @Test func carriageReturnsAreTrimmed() {
        #expect(collect("::done::Opened\r\n").message?.text == "Opened")
    }
}
