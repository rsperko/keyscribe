import Testing
@testable import KeyScribeKit

struct VoiceCommandGrammarTests {
    @Test(arguments: [
        ("switch to ghostty", "ghostty"),
        ("Switch to Chrome.", "chrome"),
        ("go to gmail", "gmail"),
        ("focus vscode", "vscode"),
        ("focus on the terminal", "terminal"),
        ("open VS Code", "vs code"),
        ("Launch Safari!", "safari"),
        ("  switch   to   the   browser  ", "browser"),
        ("Switch to, Slack.", "slack"),
        ("switch to Mail?", "mail"),
    ])
    func parsesAFocusCommand(transcript: String, target: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == .focus(target: target))
    }

    @Test(arguments: [
        "switch two", "switch too", "which to", "which two", "which too",
        "witch to", "witch two", "witch too", "go two", "go too",
    ])
    func acceptsSoundAlikesOnlyAsCommandPrefixes(_ prefix: String) {
        #expect(VoiceCommandGrammar.parse("\(prefix) the Mail.") == .focus(target: "mail"))
        #expect(VoiceCommandGrammar.parse(prefix) == nil)
        #expect(VoiceCommandGrammar.parse("\(prefix) the") == nil)
        #expect(VoiceCommandGrammar.parse("please \(prefix) Mail") == nil)
    }

    @Test func preservesSoundAlikesInsideTheTarget() {
        #expect(VoiceCommandGrammar.parse("Which too Which to Choose") == .focus(target: "which to choose"))
        #expect(VoiceCommandGrammar.parse("open Witch Too") == .focus(target: "witch too"))
    }

    @Test(arguments: ["go back", "Go back.", "GO BACK!", "  go   back "])
    func parsesGoBack(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == .goBack)
    }

    @Test(arguments: [("run Foo", "foo"), ("Run deploy Staging-2!", "deploy staging 2")])
    func parsesAScriptCommand(transcript: String, target: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == .runScript(target: target))
    }

    @Test(arguments: [
        "",
        "   ",
        "switch to",
        "Go to.",
        "open the",
        "please switch to chrome",
        "I want to switch to chrome",
        "go back to slack",
        "hello world",
        "switchboard",
        "opening",
        "run",
        "please run foo",
        "running foo",
        "which Mail",
        "witch Mail",
        "which together Mail",
        "witch toolbox",
        "go toolbox",
        "lunch Safari",
        "ran deploy",
        "Ron deploy",
        "rune deploy",
        "go bag",
    ])
    func rejectsAnythingElse(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == nil)
    }

    @Test func keyFoldsCaseDiacriticsAndPunctuation() {
        #expect(VoiceCommandText.key("Café — Notes.") == "cafe notes")
        #expect(VoiceCommandText.key("VS-Code") == "vs code")
        #expect(VoiceCommandText.compact("VS Code") == "vscode")
    }

    @Test(arguments: VoiceCommandPhrase.allCases)
    func everyTaughtPhraseIsOneTheGrammarAccepts(_ phrase: VoiceCommandPhrase) {
        for words in phrase.words {
            let intent = VoiceCommandGrammar.parse(phrase == .goBack ? words : "\(words) mail")
            switch phrase {
            case .focus: #expect(intent == .focus(target: "mail"))
            case .run: #expect(intent == .runScript(target: "mail"))
            case .goBack: #expect(intent == .goBack)
            }
        }
    }

    @Test func theGuidanceTeachesEveryPhrase() {
        #expect(VoiceCommandPhrase.guidance
                == "say \u{201C}switch to\u{201D} or \u{201C}open\u{201D} an app or place, \u{201C}run\u{201D} a script or shortcut, or \u{201C}go back\u{201D}")
    }
}
