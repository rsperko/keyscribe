import Foundation
import Testing
@testable import KeyScribeKit

struct CheatSheetPhraseTests {
    private static let sheet = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/cheat_sheet.md")
    private static let alternativesPage = "Other ways to say it"

    private static let fills = [
        "[name]": "backend", "[instruction]": "run the tests", "[question]": "what changed", "[message]": "lunch is at noon",
        "[words]": "scratch that", "[app]": "Mail", "[app or window]": "Notes", "[saved place]": "reading list",
        "[saved action]": "new note", "[input]": "buy milk", "[tab search]": "browser", "[title or site]": "inbox",
    ]

    enum Effect {
        case edit(String)
        case discard
        case help
        case mode(String)
        case voice(VoiceCommandResolution)
        case answer(VoiceCommandChoiceAnswer)
        case address(AgentAddress)
        case status(AgentStatusQuery)
        case rename(String)
        case intent(VoiceCommandIntent)
    }

    private static let mail = VoiceCommandCatalog.App(name: "Mail", bundleId: "com.apple.mail")
    private static let notes = VoiceCommandCatalog.App(name: "Notes", bundleId: "com.apple.Notes")
    private static let readingList = VoiceCommandPlace(name: "Reading list", target: .url("https://example.com/list"))
    private static let browser = VoiceCommandPlace(name: "Browser", target: .tabSearch)
    private static let newNote = VoiceCommandScript(name: "New note", run: ["/bin/note", "{text}"])
    private static let inbox = VoiceCommandCatalog.Tab(
        browserBundleId: "com.apple.Safari", window: 1, tab: 1, url: "https://mail.example.com/", title: "Inbox")

    private static let toBackend = AgentAddress.name("backend", body: "run the tests")

    private static let expected: [String: [String: Effect]] = [
        "Dictate & fix": [
            "insert new line": .edit("alpha beta\ngamma delta"),
            "insert a new line": .edit("alpha beta\ngamma delta"),
            "insert newline": .edit("alpha beta\ngamma delta"),
            "insert new paragraph": .edit("alpha beta\n\ngamma delta"),
            "insert a new paragraph": .edit("alpha beta\n\ngamma delta"),
            "insert tab character": .edit("alpha beta\tgamma delta"),
            "insert a tab character": .edit("alpha beta\tgamma delta"),
            "scratch that": .edit("gamma delta"),
            "never mind": .discard,
            "start over": .discard,
            "insert clipboard contents": .edit("alpha beta COPIED gamma delta"),
            "insert the clipboard contents": .edit("alpha beta COPIED gamma delta"),
            "insert clipboard as code": .edit("alpha beta\n```\nCOPIED\n```\ngamma delta"),
            "insert clipboard as a code block": .edit("alpha beta\n```\nCOPIED\n```\ngamma delta"),
            "begin verbatim scratch that end verbatim": .edit("alpha beta scratch that gamma delta"),
            "what can I say?": .help,
            "show commands": .help,
        ],
        "Format & choose a mode": [
            "lunch is at noon as an email": .mode("email"),
            "run the tests as a prompt": .mode("ai-prompt"),
            "as prompt": .mode("ai-prompt"),
        ],
        "Move around & run commands": [
            "open Mail": .voice(.action(.app(mail))),
            "launch Mail": .voice(.action(.app(mail))),
            "please open Mail": .voice(.action(.app(mail))),
            "open Mail, please": .voice(.action(.app(mail))),
            "switch to Notes": .voice(.action(.app(notes))),
            "go to Notes": .voice(.action(.app(notes))),
            "focus Notes": .voice(.action(.app(notes))),
            "focus on Notes": .voice(.action(.app(notes))),
            "open reading list": .voice(.action(.place(readingList, .openURL("https://example.com/list", browser: nil)))),
            "run new note buy milk": .voice(.action(.script(newNote, arguments: ["buy milk"]))),
            "open browser inbox": .voice(.action(.tab(inbox))),
            "go back": .voice(.action(.goBack)),
            "repeat that": .voice(.action(.repeatSummary)),
            "say that again": .voice(.action(.repeatSummary)),
            "cancel": .voice(.cancelled),
            "never mind": .voice(.cancelled),
            "what can I say?": .help,
            "two": .answer(.select(1)),
            "number two": .answer(.select(1)),
            "second": .answer(.select(1)),
            "the second one": .answer(.select(1)),
            "the last one": .answer(.select(1)),
        ],
        "Talk to coding agents": [
            "tell backend run the tests": .address(toBackend),
            "backend, run the tests": .address(toBackend),
            "ask backend what changed": .address(.name("backend", body: "what changed")),
            "select backend": .address(.select(.name("backend", body: ""))),
            "choose backend": .address(.select(.name("backend", body: ""))),
            "open backend": .address(.open(.name("backend", body: ""))),
            "switch to backend": .address(.open(.name("backend", body: ""))),
            "go to backend": .address(.open(.name("backend", body: ""))),
            "tell conversation two run the tests": .address(.row(2, body: "run the tests")),
            "select conversation two": .address(.select(.row(2, body: ""))),
            "open session two": .address(.open(.row(2, body: ""))),
            "check on backend": .status(.check(.name("backend", body: ""))),
            "check on conversation two": .status(.check(.row(2, body: ""))),
            "check on this conversation": .status(.check(nil)),
            "check on all conversations": .status(.all),
            "who needs me?": .status(.all),
            "rename this conversation to backend": .rename("backend"),
            "rename this session to backend": .rename("backend"),
            "name this conversation backend": .rename("backend"),
            "call this conversation backend": .rename("backend"),
            "repeat that": .intent(.repeatSummary),
            "cancel": .intent(.cancel),
            "never mind": .intent(.cancel),
            "what can I say?": .help,
        ],
    ]

    struct Phrase: CustomStringConvertible {
        let section: String
        let said: String
        var description: String { "\(section): \(said)" }
    }

    static func phrases() throws -> [Phrase] {
        var page = ""
        var heading = ""
        var phrases: [Phrase] = []
        for line in try String(contentsOf: sheet, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { page = String(line.dropFirst(3)) }
            if line.hasPrefix("### ") { heading = String(line.dropFirst(4)) }
            let section = page == alternativesPage ? heading : page
            guard line.hasPrefix("| `") else { continue }
            let say = line.split(separator: "|", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            for span in say.components(separatedBy: "`").enumerated() where span.offset % 2 == 1 {
                var said = span.element
                for (placeholder, value) in fills { said = said.replacingOccurrences(of: placeholder, with: value) }
                guard !said.contains("[") else { continue }
                phrases.append(Phrase(section: section, said: said))
            }
        }
        return phrases
    }

    @Test func theSheetHasPhrasesInEverySection() throws {
        let sections = Set(try Self.phrases().map(\.section))
        for expected in Self.expected.keys { #expect(sections.contains(expected)) }
    }

    @Test(arguments: try phrases())
    func everyPhraseOnTheSheetDoesWhatItsRowSays(_ phrase: Phrase) throws {
        let effect = try #require(Self.expected[phrase.section]?[phrase.said], "no expected effect for \(phrase); add one here")
        switch effect {
        case .help: #expect(VoiceCommandGrammar.parse(phrase.said) == .help)
        case .edit(let output): #expect(Self.edited(phrase.said) == output)
        case .discard: #expect(Self.discards(phrase.said))
        case .mode(let id): #expect(Self.routed(phrase.said) == id)
        case .voice(let resolution): #expect(VoiceCommandResolver.resolve(phrase.said, catalog: Self.catalog) == resolution)
        case .answer(let answer): #expect(VoiceCommandChoiceAnswer.parse(phrase.said, count: 2) == answer)
        case .address(let address): #expect(AgentAddress.parse(phrase.said, names: ["backend"]) == address)
        case .status(let query): #expect(AgentStatusQuery.parse(phrase.said, names: ["backend"]) == query)
        case .rename(let name): #expect(AgentRename.parse(phrase.said) == .rename(name))
        case .intent(let intent): #expect(VoiceCommandGrammar.parse(phrase.said) == intent)
        }
    }

    private static var catalog: VoiceCommandCatalog {
        VoiceCommandCatalog(
            places: [readingList, browser], scripts: [newNote], runningApps: [mail, notes], installedApps: [mail, notes],
            tabs: [inbox], windows: .complete([]))
    }

    private static var pipeline: Pipeline {
        TakeStages.dictation(
            text: TakeStages.text(liveEdits: true, rules: [], numbers: false, dictionary: []),
            clip: { ClipboardTokenizer.Clip(text: "COPIED") }, redaction: false)
    }

    private static func edited(_ said: String) -> String {
        let pipeline = pipeline
        let payload = pipeline.forward("alpha beta, \(said), gamma delta")
        return pipeline.restore(payload.text)
    }

    private static func discards(_ said: String) -> Bool {
        pipeline.forward("alpha beta. \(said)").discarded
    }

    private static func routed(_ said: String) -> String? {
        let text = said.hasPrefix("as ") ? "lunch is at noon \(said)" : said
        let modes = ModeStore.starterModes().map { mode -> Mode in
            var mode = mode
            mode.enabled = true
            return mode
        }
        return ModeResolver.resolvePhaseB(eligibleModes: modes, transcript: text).routedModeId
    }
}
