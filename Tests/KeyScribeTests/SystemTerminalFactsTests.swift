import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct SystemTerminalFactsTests {
    @Test func processArgumentsSplitIntoTheExecutableArgumentsAndOnlyTheEnvironmentOpenUses() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        for part in ["/opt/homebrew/bin/herdr", "", "", "herdr", "server", "HERDR_SOCKET_PATH=/s=1.sock", "NOEQUALS", "TERM=xterm", ""] {
            buffer += Array(part.utf8) + [0]
        }
        let parsed = SystemTerminalFacts.parse(procargs: buffer)
        #expect(parsed.executable == "/opt/homebrew/bin/herdr")
        #expect(parsed.arguments == ["herdr", "server"])
        #expect(parsed.environment == ["HERDR_SOCKET_PATH": "/s=1.sock"])
    }

    @Test func truncatedProcessArgumentsReadAsEmpty() {
        #expect(SystemTerminalFacts.parse(procargs: [1, 0]).arguments.isEmpty)
    }

    @Test func thisProcessIsReadWithItsParentAndArguments() throws {
        let process = try #require(SystemTerminalFacts().process(Int(getpid())))
        #expect(process.parent == Int(getppid()))
        #expect(process.arguments.first == CommandLine.arguments.first)
        #expect(Set(process.environment.keys).isSubset(of: TerminalRoutes.environmentKeys))
    }
}
