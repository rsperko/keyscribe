import Testing
@testable import KeyScribeKit

struct SpokenHelpCoverageTests {
    private static let excluded: Set<String> = ["help", "answer"]

    static let pages = ["Dictate & fix", "Move around & run commands", "Talk to agents"]

    private static func help(for page: String) -> [SpokenHelp.Row] {
        switch page {
        case "Dictate & fix":
            let help = SpokenHelp.dictation(title: "", stages: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: []))
            return help.group(SpokenHelp.Heading.edits)
        case "Move around & run commands":
            let help = SpokenHelp.voiceCommands(
                title: "", apps: ["Mail", "Notes"],
                places: [
                    VoiceCommandPlace(name: "Reading list", target: .url("https://example.com/list")),
                    VoiceCommandPlace(name: "Browser", target: .tabSearch),
                ],
                scripts: [VoiceCommandScript(name: "New note", run: ["/bin/note", "{text}"])],
                findsInApps: true, readsReplies: true, canRepeat: true, stages: [])
            return help.group(SpokenHelp.Heading.commands) + help.group(SpokenHelp.Heading.saved)
        default:
            let help = SpokenHelp.agent(
                title: "", focused: "backend", example: "backend", readsReplies: true, canRepeat: true, stages: [])
            return help.group(SpokenHelp.Heading.commands)
        }
    }

    @Test(arguments: pages)
    func theHelpCoversTheSameCommandsAsItsCheatSheetPage(_ page: String) throws {
        let sheet = Set(try CheatSheetPhraseTests.phrases().filter { $0.section == page && !$0.isAlternative }
            .compactMap { CheatSheetPhraseTests.kind(of: $0.said, on: page) }).subtracting(Self.excluded)
        let fill = try #require(CheatSheetPhraseTests.pageFills[page])
        let shown = Set(Self.help(for: page).compactMap { row in
            CheatSheetPhraseTests.kind(of: row.said.replacingOccurrences(of: "\u{2026}", with: fill), on: page)
        })
        #expect(!sheet.isEmpty)
        #expect(sheet.subtracting(shown).sorted() == [], "on the cheat sheet but not in the help")
        #expect(shown.subtracting(sheet).sorted() == [], "in the help but not on the cheat sheet")
    }
}
