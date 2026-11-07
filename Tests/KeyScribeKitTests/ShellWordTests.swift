import Testing
@testable import KeyScribeKit

struct ShellWordTests {
    @Test func aPathUnderHomeKeepsAnUnquotedTildeSoTheShellStillExpandsIt() {
        #expect(ShellWord.path("/Users/a/.claude-work", home: "/Users/a") == "~/.claude-work")
        #expect(ShellWord.path("/Users/a/claude work", home: "/Users/a") == "~/'claude work'")
        #expect(ShellWord.path("/Users/a/it's $HOME", home: "/Users/a/") == "~/'it'\\''s $HOME'")
    }

    @Test func aPathElsewhereIsQuotedWhole() {
        #expect(ShellWord.path("/Volumes/My Disk/.claude", home: "/Users/a") == "'/Volumes/My Disk/.claude'")
        #expect(ShellWord.path("/opt/claude", home: "/Users/a") == "/opt/claude")
        #expect(ShellWord.path("/Users/ab/x", home: "/Users/a") == "/Users/ab/x")
    }
}
