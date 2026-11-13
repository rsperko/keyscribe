import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct SystemTerminalFactsTests {
    @Test func processArgumentsSplitIntoTheExecutableArgumentsAndOnlyTheEnvironmentOpenUses() throws {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        for part in ["/opt/homebrew/bin/herdr", "", "", "herdr", "server", "HERDR_SOCKET_PATH=/s=1.sock", "NOEQUALS", "TERM=xterm", ""] {
            buffer += Array(part.utf8) + [0]
        }
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: ResolvedSurfaces.builtIn.environmentKeys))
        #expect(parsed.executable == "/opt/homebrew/bin/herdr")
        #expect(parsed.arguments == ["herdr", "server"])
        #expect(parsed.environment == ["HERDR_SOCKET_PATH": "/s=1.sock"])
    }

    @Test func truncatedProcessArgumentsAreUnreadableNotEmpty() {
        #expect(SystemTerminalFacts.parse(procargs: [1, 0], keeping: []) == nil)
        #expect(SystemTerminalFacts.parse(procargs: [], keeping: []) == nil)
    }

    @Test func aRewrittenTitleKeepsTheEnvironmentAfterItsPadding() throws {
        let buffer = Self.procargs(
            argc: 4, executable: "/usr/local/bin/node",
            argumentArea: Array("pi".utf8) + [UInt8](repeating: 0, count: 90),
            environment: ["TERM_PROGRAM=tmux", "TMUX=/private/tmp/tmux-501/default,1,0", "HOME=/Users/a"])
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: Self.keys))
        #expect(parsed.executable == "/usr/local/bin/node")
        #expect(parsed.arguments == ["pi"])
        #expect(parsed.environment == ["TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,1,0"])
    }

    @Test func anOrdinaryArgumentHoldingAnEqualsSignStaysAnArgument() throws {
        let buffer = Self.procargs(
            argc: 3, executable: "/usr/bin/env",
            argumentArea: Array("env\0TERM_PROGRAM=fake\0run\0".utf8),
            environment: ["TERM_PROGRAM=Apple_Terminal"])
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: Self.keys))
        #expect(parsed.arguments == ["env", "TERM_PROGRAM=fake", "run"])
        #expect(parsed.environment == ["TERM_PROGRAM": "Apple_Terminal"])
    }

    @Test func anEmptyArgumentKeepsTheArgumentsAfterItOutOfTheEnvironment() throws {
        let buffer = Self.procargs(
            argc: 3, executable: "/usr/bin/env",
            argumentArea: Array("env\0\0TERM_PROGRAM=fake\0".utf8),
            environment: ["TERM_PROGRAM=Apple_Terminal"])
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: Self.keys))
        #expect(parsed.arguments == ["env", "", "TERM_PROGRAM=fake"])
        #expect(parsed.environment == ["TERM_PROGRAM": "Apple_Terminal"])
    }

    @Test func aTitleFillingTheWholeArgumentAreaReadsLikeAnOrdinaryProcess() throws {
        let buffer = Self.procargs(
            argc: 1, executable: "/usr/local/bin/node",
            argumentArea: Array("pi --a-very-long-rewritten-title".utf8) + [0],
            environment: ["TERM_PROGRAM=WarpTerminal"])
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: Self.keys))
        #expect(parsed.arguments == ["pi --a-very-long-rewritten-title"])
        #expect(parsed.environment == ["TERM_PROGRAM": "WarpTerminal"])
    }

    @Test func aBufferCutInsideTheEnvironmentKeepsWhatItRead() throws {
        var buffer = Self.procargs(
            argc: 1, executable: "/bin/zsh", argumentArea: Array("-zsh".utf8) + [0],
            environment: ["TERM_PROGRAM=ghostty", "TMUX=/tmp/x"])
        buffer.removeLast(4)
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: Self.keys))
        #expect(parsed.environment["TERM_PROGRAM"] == "ghostty")
    }

    @Test func aReadableProcessWithoutAllowlistedKeysHasAnEmptyEnvironment() throws {
        let buffer = Self.procargs(argc: 1, executable: "/bin/zsh", argumentArea: Array("zsh".utf8) + [0], environment: ["HOME=/Users/a"])
        let parsed = try #require(SystemTerminalFacts.parse(procargs: buffer, keeping: Self.keys))
        #expect(parsed.environment.isEmpty)
    }

    static let keys: Set<String> = ["TERM_PROGRAM", "TMUX"]

    static func procargs(argc: Int32, executable: String, argumentArea: [UInt8], environment: [String]) -> [UInt8] {
        var buffer = withUnsafeBytes(of: argc) { Array($0) }
        buffer += Array(executable.utf8) + [0, 0, 0, 0]
        buffer += argumentArea
        for entry in environment { buffer += Array(entry.utf8) + [0] }
        buffer += [0] + Array("executable_path=/x".utf8) + [0]
        return buffer
    }

    @Test func aProcessListThatFailsIsUnreadableNotEmpty() {
        #expect(SystemTerminalFacts.listed { 3 } == 3)
        #expect(SystemTerminalFacts.listed { 0 } == 0)
        #expect(SystemTerminalFacts.listed { errno = EPERM; return 0 } == nil)
        #expect(SystemTerminalFacts.listed { -1 } == nil)
    }

    @Test func thisProcessesChildrenAndNamedProcessesCanBeListed() throws {
        let facts = SystemTerminalFacts(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys)
        #expect(facts.children(of: Int(getpid())) != nil)
        let named = try #require(facts.processes(named: (CommandLine.arguments[0] as NSString).lastPathComponent))
        #expect(named.contains { $0.pid == Int(getpid()) })
    }

    @Test func thisProcessIsReadWithItsParentAndArguments() throws {
        let process = try #require(SystemTerminalFacts(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys).process(Int(getpid())))
        #expect(process.parent == Int(getppid()))
        #expect(process.arguments.first == CommandLine.arguments.first)
        #expect(Set(process.environment.keys).isSubset(of: ResolvedSurfaces.builtIn.environmentKeys))
    }

    @Test func thisProcessIsReadWithItsWorkingFolderAndAStableStartIdentity() throws {
        let first = try #require(SystemTerminalFacts(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys).process(Int(getpid())))
        let second = try #require(SystemTerminalFacts(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys).process(Int(getpid())))
        #expect(first.directory == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        #expect(first.argumentsReadable)
        let started = try #require(first.startedAt)
        #expect(started == second.startedAt)
        #expect(started <= Int(Date().timeIntervalSince1970 * 1000))
        #expect(ProcessStart.read(pid: Int(getpid())) == .started(milliseconds: started))
    }
}
