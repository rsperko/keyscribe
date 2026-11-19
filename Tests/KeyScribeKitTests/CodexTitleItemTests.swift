import Foundation
import KeyScribeKit
import Testing

struct CodexTitleItemTests {
    private let createdLine = #"terminal_title = ["spinner", "project", "thread-id"]"#

    private func roundTrips(_ original: String?, to added: String, record: CodexTitleItem.Record, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = CodexTitleItem.adding(to: original)
        #expect(result?.text == added, sourceLocation: sourceLocation)
        #expect(result?.record == record, sourceLocation: sourceLocation)
        #expect(CodexTitleItem.inspect(added) == .present, sourceLocation: sourceLocation)
        #expect(CodexTitleItem.removing(from: added, record: record) == (original ?? ""), sourceLocation: sourceLocation)
    }

    @Test func noFileOrAnEmptyOneGetsATuiTableWithCodexsDefaultsAndOurs() {
        #expect(CodexTitleItem.inspect(nil) == .missing)
        #expect(CodexTitleItem.inspect("") == .missing)
        roundTrips(nil, to: "[tui]\n\(createdLine)\n", record: .createdKey(createdTable: true, addedLineBreak: false))
        roundTrips("", to: "[tui]\n\(createdLine)\n", record: .createdKey(createdTable: true, addedLineBreak: false))
    }

    @Test func aFileWithoutTuiKeepsEveryByteAndGetsOurTableAtTheEnd() {
        let original = """
            # my settings
            model = "gpt-6" # pinned

            [profiles.fast]
            model = "x"

            """
        #expect(CodexTitleItem.inspect(original) == .missing)
        roundTrips(original, to: original + "\n[tui]\n\(createdLine)\n", record: .createdKey(createdTable: true, addedLineBreak: false))
        roundTrips(#"model = "gpt-6""#, to: "model = \"gpt-6\"\n\n[tui]\n\(createdLine)\n", record: .createdKey(createdTable: true, addedLineBreak: true))
    }

    @Test func aTuiTableWithoutTheKeyGetsOurKeyRightUnderItsHeader() {
        let original = """
            model = "gpt-6"
            [ tui ] # ui
            # keep this
            notifications = true

            [other]
            x = 1

            """
        #expect(CodexTitleItem.inspect(original) == .missing)
        let added = original.replacingOccurrences(of: "[ tui ] # ui\n", with: "[ tui ] # ui\n\(createdLine)\n")
        roundTrips(original, to: added, record: .createdKey(createdTable: false, addedLineBreak: false))
        roundTrips("a = 1\n[tui]", to: "a = 1\n[tui]\n\(createdLine)", record: .createdKey(createdTable: false, addedLineBreak: false))
    }

    @Test func aSingleLineArrayGetsOursAppendedInItsOwnStyle() {
        let original = "[tui]\nterminal_title = [\"project\", 'spinner'] # mine\n"
        #expect(CodexTitleItem.inspect(original) == .missing)
        roundTrips(original, to: "[tui]\nterminal_title = [\"project\", 'spinner', \"thread-id\"] # mine\n", record: .appended)
        roundTrips("[tui]\nterminal_title = []\n", to: "[tui]\nterminal_title = [\"thread-id\"]\n", record: .appended)
        roundTrips("[tui]\nterminal_title = [\"project\",]\n", to: "[tui]\nterminal_title = [\"project\", \"thread-id\",]\n", record: .appended)
    }

    @Test func aMultiLineArrayWithATrailingCommaAndCommentsGetsOurOwnLine() {
        let original = """
            [tui]
            terminal_title = [
              "spinner", # spins
              # the folder
              "project",
            ]
            theme = "dark"

            """
        let added = original.replacingOccurrences(of: "  \"project\",\n", with: "  \"project\",\n  \"thread-id\",\n")
        roundTrips(original, to: added, record: .appended)
    }

    @Test func aMultiLineArrayWithoutATrailingCommaKeepsItsStyle() {
        let original = """
            [tui]
            terminal_title = [
                "spinner",
                "project" # last
            ]

            """
        let added = original.replacingOccurrences(of: "    \"project\" # last\n", with: "    \"project\", # last\n    \"thread-id\"\n")
        roundTrips(original, to: added, record: .appended)
        roundTrips("[tui]\nterminal_title = [\n  \"spinner\"]\n", to: "[tui]\nterminal_title = [\n  \"spinner\", \"thread-id\"]\n", record: .appended)
        roundTrips("[tui]\nterminal_title = [\n  \"spinner\"\n]\n", to: "[tui]\nterminal_title = [\n  \"spinner\",\n  \"thread-id\"\n]\n", record: .appended)
    }

    @Test func windowsLineEndingsAreKept() {
        let original = "a = 1\r\n[tui]\r\nterminal_title = [\r\n  \"spinner\",\r\n]\r\n"
        roundTrips(original, to: "a = 1\r\n[tui]\r\nterminal_title = [\r\n  \"spinner\",\r\n  \"thread-id\",\r\n]\r\n", record: .appended)
        let bare = "[tui]\r\nterminal_title = [\r\n  \"spinner\"\r\n]\r\n"
        roundTrips(bare, to: "[tui]\r\nterminal_title = [\r\n  \"spinner\",\r\n  \"thread-id\"\r\n]\r\n", record: .appended)
        roundTrips("[tui]\r\nx = 1\r\n", to: "[tui]\r\n\(createdLine)\r\nx = 1\r\n", record: .createdKey(createdTable: false, addedLineBreak: false))
    }

    @Test func windowsLineEndingsAreKeptWhenOurTableOrKeyIsAdded() {
        roundTrips("model = \"x\"\r\n", to: "model = \"x\"\r\n\r\n[tui]\r\n\(createdLine)\r\n", record: .createdKey(createdTable: true, addedLineBreak: false))
        roundTrips("a = 1\r\n[tui]", to: "a = 1\r\n[tui]\r\n\(createdLine)", record: .createdKey(createdTable: false, addedLineBreak: false))
    }

    @Test func aFileThatStartsWithAByteOrderMarkIsEditedAndKeepsIt() {
        let original = "\u{FEFF}[tui]\nterminal_title = [\"project\"]\n"
        roundTrips(original, to: "\u{FEFF}[tui]\nterminal_title = [\"project\", \"thread-id\"]\n", record: .appended)
    }

    @Test func ourItemFirstInALineIsTakenOutWithoutLeavingASpace() {
        #expect(CodexTitleItem.removing(from: "[tui]\nterminal_title = [\"thread-id\", \"b\"]\n", record: .appended) == "[tui]\nterminal_title = [\"b\"]\n")
    }

    @Test func aKeyWeCreatedStaysOursWhenOurItemIsPutBackInIt() {
        let created = CodexTitleItem.Record.createdKey(createdTable: true, addedLineBreak: false)
        #expect(CodexTitleItem.keeping(created, over: .appended) == created)
        #expect(CodexTitleItem.keeping(.appended, over: created) == created)
        #expect(CodexTitleItem.keeping(.alreadyPresent, over: .appended) == .appended)
    }

    @Test func textThatOnlyLooksLikeATuiTableIsNotMistakenForOne() {
        let original = """
            notes = \"\"\"
            [tui]
            terminal_title = []
            \"\"\"
            paths = [ "[tui]", 'a#b' ] # [tui]

            [[profiles]]
            name = "tui"

            """
        #expect(CodexTitleItem.inspect(original) == .missing)
        roundTrips(original, to: original + "\n[tui]\n\(createdLine)\n", record: .createdKey(createdTable: true, addedLineBreak: false))
        let quoted = "[\"tui\"]\n\"terminal_title\" = [\"spinner\"]\n"
        roundTrips(quoted, to: "[\"tui\"]\n\"terminal_title\" = [\"spinner\", \"thread-id\"]\n", record: .appended)
    }

    @Test func anItemAlreadyThereIsLeftAlone() {
        let original = "[tui]\nterminal_title = ['thread-id', \"spinner\"]\n"
        #expect(CodexTitleItem.inspect(original) == .present)
        #expect(CodexTitleItem.adding(to: original)?.text == original)
        #expect(CodexTitleItem.adding(to: original)?.record == .alreadyPresent)
        #expect(CodexTitleItem.removing(from: original, record: .alreadyPresent) == original)
    }

    @Test func shapesTheEditDoesNotHandleAreUnsupportedAndNeverRewritten() {
        for text in [
            "tui = { terminal_title = [\"spinner\"] }\n",
            "tui = { theme = \"dark\" }\n",
            "tui.terminal_title = [\"spinner\"]\n",
            "tui.theme = \"dark\"\n",
            "[tui]\nterminal_title = \"spinner\"\n",
            "[[tui]]\nx = 1\n",
            "tui = 3\n",
        ] {
            #expect(CodexTitleItem.inspect(text) == .unsupported, "\(text)")
            #expect(CodexTitleItem.adding(to: text) == nil, "\(text)")
            #expect(CodexTitleItem.removing(from: text, record: .appended) == nil, "\(text)")
        }
    }

    @Test func aFileThatDoesNotParseIsUnreadableAndNeverRewritten() {
        let text = "[tui\nterminal_title = [\n"
        #expect(CodexTitleItem.inspect(text) == .unreadable)
        #expect(CodexTitleItem.adding(to: text) == nil)
        #expect(CodexTitleItem.removing(from: text, record: .createdKey(createdTable: true, addedLineBreak: false)) == nil)
    }

    @Test func removingLeavesTheUsersChangesAndTakesOnlyOurItem() {
        let changed = "[tui]\nterminal_title = [\"project\", \"thread-id\"]\n"
        #expect(CodexTitleItem.removing(from: changed, record: .createdKey(createdTable: true, addedLineBreak: false)) == "[tui]\nterminal_title = [\"project\"]\n")
        let after = "[tui]\nterminal_title = [\"a\", \"thread-id\", \"b\"]\n"
        #expect(CodexTitleItem.removing(from: after, record: .appended) == "[tui]\nterminal_title = [\"a\", \"b\"]\n")
        let gone = "[tui]\nterminal_title = [\"a\"]\n"
        #expect(CodexTitleItem.removing(from: gone, record: .appended) == gone)
        #expect(CodexTitleItem.removing(from: "x = 1\n", record: .createdKey(createdTable: true, addedLineBreak: true)) == "x = 1\n")
        #expect(CodexTitleItem.removing(from: nil, record: .appended) == "")
    }

    @Test func ourTableStaysWhileTheUserKeepsSomethingInIt() {
        let added = "x = 1\n\n[tui]\n\(createdLine)\ntheme = \"dark\"\n"
        #expect(CodexTitleItem.removing(from: added, record: .createdKey(createdTable: true, addedLineBreak: false)) == "x = 1\n\n[tui]\ntheme = \"dark\"\n")
        let followed = "x = 1\n\n[tui]\n\(createdLine)\n\n[other]\ny = 2\n"
        #expect(CodexTitleItem.removing(from: followed, record: .createdKey(createdTable: true, addedLineBreak: false)) == "x = 1\n\n[other]\ny = 2\n")
    }

    @Test func theRecordSurvivesBeingSaved() throws {
        for record in [CodexTitleItem.Record.createdKey(createdTable: true, addedLineBreak: false), .appended, .alreadyPresent] {
            let saved = try JSONEncoder().encode(record)
            #expect(try JSONDecoder().decode(CodexTitleItem.Record.self, from: saved) == record)
        }
    }
}
