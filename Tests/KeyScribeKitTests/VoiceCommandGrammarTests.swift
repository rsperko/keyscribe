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

    @Test(arguments: ["go back", "Go back.", "GO BACK!", "  go   back "])
    func parsesGoBack(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == .goBack)
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
    ])
    func rejectsAnythingElse(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == nil)
    }

    @Test func keyFoldsCaseDiacriticsAndPunctuation() {
        #expect(VoiceCommandText.key("Café — Notes.") == "cafe notes")
        #expect(VoiceCommandText.key("VS-Code") == "vs code")
        #expect(VoiceCommandText.compact("VS Code") == "vscode")
    }
}
