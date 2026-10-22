import Foundation
import Testing
@testable import KeyScribeKit

struct VoiceCommandLineShellTests {
    private static let arguments = [
        "plain", "buy milk; rm -rf ~", "", "  ", "it's", "~/x", "=sh", "a=b", "$HOME", "`id`", "*", "!",
        "{a,b}", "#x", "x#", "--flag", "%1", "^x", "a\\b", "\"quoted\"", "tab\there", "naïve",
    ]

    private func output(of shell: String, running line: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shell.hasSuffix("zsh") ? ["-f", "-c", line] : ["-c", line]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: ["/bin/zsh", "/bin/sh"])
    func aCopiedCommandLinePassesTheSameArgumentsInAShell(shell: String) throws {
        let script = VoiceCommandScript(name: "Echo", run: ["/usr/bin/printf", "[%s]", "{text}"])
        let line = script.commandLine(arguments: ["[%s]"] + Self.arguments)
        #expect(try output(of: shell, running: line) == Self.arguments.map { "[\($0)]" }.joined())
    }
}
