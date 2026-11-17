import Foundation
import Testing
@testable import KeyScribeKit

struct ShellEnvironmentTests {
    private let nonce = "n0nce"
    private let keys: Set<String> = ["CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "BB_DATA_DIR"]

    private func output(_ entries: [String], before: String = "", after: String = "") -> Data {
        var data = Data(before.utf8)
        data += Data(ShellEnvironment.begin(nonce).utf8)
        for entry in entries { data += Data(entry.utf8) + Data([0]) }
        data += Data(ShellEnvironment.end(nonce).utf8)
        data += Data(after.utf8)
        return data
    }

    @Test func keepsPathAndOnlyTheKeysAskedFor() {
        let parsed = ShellEnvironment.parse(output([
            "PATH=/Users/a/.local/bin:/opt/homebrew/bin:/usr/bin", "CLAUDE_CONFIG_DIR=/Users/a/.claude-work", "OPENAI_API_KEY=sk-secret",
            "PI_CODING_AGENT_DIR=~/pi", "BB_DATA_DIR=/Users/a/.bb-dev", "HOME=/Users/a",
        ]), nonce: nonce, keys: keys)
        #expect(parsed?.values == [
            "PATH": "/Users/a/.local/bin:/opt/homebrew/bin:/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/a/.claude-work", "PI_CODING_AGENT_DIR": "~/pi",
            "BB_DATA_DIR": "/Users/a/.bb-dev",
        ])
    }

    @Test func noiseAroundTheMarkersIsIgnored() {
        let parsed = ShellEnvironment.parse(
            output(["PATH=/opt/homebrew/bin:/usr/bin"], before: "Welcome back!\nPATH=/evil\n\u{1b}]0;title\u{7}", after: "logout\nPATH=/evil2\n"),
            nonce: nonce, keys: keys)
        #expect(parsed?.path == ["/opt/homebrew/bin", "/usr/bin"])
    }

    @Test func aValueSpanningLinesStaysWhole() {
        let parsed = ShellEnvironment.parse(output(["CLAUDE_CONFIG_DIR=/Users/a/odd\nname", "PATH=/usr/bin"]), nonce: nonce, keys: keys)
        #expect(parsed?.values["CLAUDE_CONFIG_DIR"] == "/Users/a/odd\nname")
    }

    @Test func outputWithoutBothMarkersIsNoAnswer() {
        var cut = output(["PATH=/usr/bin"])
        cut.removeLast(ShellEnvironment.end(nonce).utf8.count)
        #expect(ShellEnvironment.parse(cut, nonce: nonce, keys: keys) == nil)
        #expect(ShellEnvironment.parse(Data("PATH=/usr/bin\n".utf8), nonce: nonce, keys: keys) == nil)
        #expect(ShellEnvironment.parse(Data(), nonce: nonce, keys: keys) == nil)
    }

    @Test func markersFromAnotherRunAreNotTrusted() {
        #expect(ShellEnvironment.parse(output(["PATH=/usr/bin"]), nonce: "other", keys: keys) == nil)
    }

    @Test func pathIsAlwaysKeptEvenWhenNoOtherKeyIsAsked() {
        let parsed = ShellEnvironment.parse(output(["PATH=/usr/bin", "CLAUDE_CONFIG_DIR=/x"]), nonce: nonce, keys: [])
        #expect(parsed?.values == ["PATH": "/usr/bin"])
    }

    @Test func theScriptNeverContainsAWholeMarker() {
        let script = ShellEnvironment.script(nonce: nonce)
        #expect(!script.contains(ShellEnvironment.begin(nonce)))
        #expect(!script.contains(ShellEnvironment.end(nonce)))
        #expect(script.contains("/usr/bin/env -0"))
    }

    @Test func onlyAbsoluteNonEmptyPathEntriesAreKept() {
        let parsed = ShellEnvironment.parse(output(["PATH=/a/bin::relative/bin:~/bin:/b/bin:/a/bin"]), nonce: nonce, keys: keys)
        #expect(parsed?.path == ["/a/bin", "/b/bin"])
    }

    @Test func interactiveLoginComesFirstExceptForPlainShells() {
        #expect(ShellEnvironment.flags(shell: "/bin/zsh") == ["-ilc", "-lc"])
        #expect(ShellEnvironment.flags(shell: "/opt/homebrew/bin/fish") == ["-ilc", "-lc"])
        #expect(ShellEnvironment.flags(shell: "/bin/sh") == ["-lc"])
        #expect(ShellEnvironment.flags(shell: "/bin/dash") == ["-lc"])
    }

    @Test func theShellComesFromTheEnvironmentThenTheAccountThenZsh() {
        #expect(ShellEnvironment.shell(environment: ["SHELL": "/opt/homebrew/bin/fish"], account: "/bin/bash") == "/opt/homebrew/bin/fish")
        #expect(ShellEnvironment.shell(environment: ["SHELL": "fish"], account: "/bin/bash") == "/bin/bash")
        #expect(ShellEnvironment.shell(environment: [:], account: nil) == "/bin/zsh")
    }

    @Test func aFolderVariableIsResolvedAgainstHome() {
        let shell = ShellEnvironment(values: ["CLAUDE_CONFIG_DIR": "~/.claude-work", "PI_CODING_AGENT_DIR": "relative/pi", "BB_DATA_DIR": ""])
        #expect(shell.folder("CLAUDE_CONFIG_DIR", home: "/Users/a") == "/Users/a/.claude-work")
        #expect(shell.folder("PI_CODING_AGENT_DIR", home: "/Users/a") == "/Users/a/relative/pi")
        #expect(shell.folder("BB_DATA_DIR", home: "/Users/a") == nil)
        #expect(shell.folder("MISSING", home: "/Users/a") == nil)
    }
}
