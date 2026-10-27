import Foundation
import Testing
@testable import KeyScribeApp
import KeyScribeKit

struct ScriptLauncherTests {
    private func script(_ body: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("run.sh")
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return (dir, file)
    }

    @Test func argumentsArriveExactlyAsGivenWithNoShell() async throws {
        let (dir, file) = try script("printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/out\"")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spoken = "staging; touch \(dir.path)/pwned $(touch \(dir.path)/pwned2)"
        #expect(await ScriptLauncher.run(program: file.path, arguments: ["--env", spoken], reportWithin: 20)
            == .finished(status: 0, lastError: nil))
        let out = try String(contentsOf: dir.appendingPathComponent("out"), encoding: .utf8)
        #expect(out == "--env\n\(spoken)\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned2").path))
    }

    @Test func aFailureReportsItsStatusAndLastErrorLine() async throws {
        let (dir, file) = try script("echo first >&2\necho 'no such environment' >&2\nexit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20)
            == .finished(status: 3, lastError: "no such environment"))
    }

    @Test func theLastErrorLineSurvivesVerboseOutput() async throws {
        let (dir, file) = try script("i=0\nwhile [ $i -lt 4000 ]; do echo \"progress line $i\" >&2; i=$((i+1)); done\necho 'REAL FINAL ERROR' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20)
            == .finished(status: 1, lastError: "REAL FINAL ERROR"))
    }

    @Test func aScriptBlockedFromControllingAnAppIsRecognized() async throws {
        let denied = "execution error: Not authorized to send Apple events to Music. (-1743)"
        let (dir, file) = try script("echo '\(denied)' >&2\necho 'cleaning up' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20)
            == .finished(status: 1, lastError: ScriptError(line: denied, blocksAutomation: true)))
    }

    @Test func reportLinesOnStandardOutputAreRead() async throws {
        let (dir, file) = try script("echo 'plain output'\necho '::choice::C1\t#general'\necho '::done::Opened #general'")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20) == .finished(
            status: 0, lastError: nil,
            report: ScriptReport(message: .init(level: .done, text: "Opened #general"),
                                 options: [.init(value: "C1", label: "#general")])))
    }

    @Test func aFailureCarriesItsReportBesideTheErrorLine() async throws {
        let (dir, file) = try script("echo '::info::Not signed in'\necho 'stack trace' >&2\nexit 4")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20) == .finished(
            status: 4, lastError: "stack trace", report: ScriptReport(message: .init(level: .info, text: "Not signed in"))))
    }

    @Test func theChoiceArrivesInTheEnvironmentBesideTheUsualOne() async throws {
        let (dir, file) = try script("printf '%s|%s' \"$KEYSCRIBE_CHOICE\" \"$HOME\" > \"$(dirname \"$0\")/env\"")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await ScriptLauncher.run(
            program: file.path, arguments: [], environment: [ScriptLauncher.choiceVariable: "C2"], reportWithin: 20)
        let env = try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)
        #expect(env == "C2|\(NSHomeDirectory())")
    }

    @Test func aChoiceIsNotSetWhenNoneWasMade() async throws {
        let (dir, file) = try script("printf '%s' \"${KEYSCRIBE_CHOICE-unset}\" > \"$(dirname \"$0\")/env\"")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20)
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "unset")
    }

    @Test func aBackgroundChildHoldingStandardOutputDoesNotHoldTheResult() async throws {
        let (dir, file) = try script("echo '::done::Started'\nsleep 8 &\nexit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20)
            == .finished(status: 0, lastError: nil, report: ScriptReport(message: .init(level: .done, text: "Started"))))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aLongRunningScriptIsLeftRunning() async throws {
        let (dir, file) = try script("sleep 5")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 0.3) == .stillRunning)
    }

    @Test func inputArrivesOnStandardInput() async throws {
        let (dir, file) = try script("cat > \"$(dirname \"$0\")/in\"")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], input: "buy milk; $(rm -rf ~)", reportWithin: 20)
            == .finished(status: 0, lastError: nil))
        #expect(try String(contentsOf: dir.appendingPathComponent("in"), encoding: .utf8) == "buy milk; $(rm -rf ~)")
    }

    @Test func aProgramThatIgnoresItsInputStillFinishes() async throws {
        let (dir, file) = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let large = String(repeating: "x", count: 1_000_000)
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], input: large, reportWithin: 20)
            == .finished(status: 0, lastError: nil))
    }

    @Test func aLongRunningScriptReportsItsResultWhenItFinishes() async throws {
        let (dir, file) = try script("sleep 1\necho 'gave up' >&2\nexit 5")
        defer { try? FileManager.default.removeItem(at: dir) }
        let late = AsyncStream<ScriptRun>.makeStream()
        let run = await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 0.2) { result in
            late.continuation.yield(result)
            late.continuation.finish()
        }
        #expect(run == .stillRunning)
        var results: [ScriptRun] = []
        for await result in late.stream { results.append(result) }
        #expect(results == [.finished(status: 5, lastError: "gave up")])
    }

    @Test func aScriptThatFinishesInTimeHasNoLateResult() async throws {
        let (dir, file) = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = LockedCount()
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20) { _ in calls.increment() }
            == .finished(status: 0, lastError: nil))
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.value == 0)
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func aScriptThatExitsWhileAChildHoldsItsErrorOutputStillReportsItsStatus() async throws {
        let (dir, file) = try script("sleep 10 &\nexit 4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 20)
            == .finished(status: 4, lastError: nil))
        #expect(Date().timeIntervalSince(start) < 7)
    }

    @Test func aMissingOrNonExecutableFileIsNotRun() async throws {
        let (dir, file) = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: dir.appendingPathComponent("absent").path, arguments: []) == .notRunnable)
        #expect(await ScriptLauncher.run(program: dir.path, arguments: []) == .notRunnable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(await ScriptLauncher.run(program: file.path, arguments: []) == .notRunnable)
    }

    @Test func aTildeProgramIsExpanded() {
        #expect(ScriptLauncher.expandedPath("~/bin/x") == FileManager.default.homeDirectoryForCurrentUser.path + "/bin/x")
        #expect(ScriptLauncher.expandedPath("/usr/bin/true") == "/usr/bin/true")
    }

    @Test func theErrorLineIsTheLastNonBlankOneAndBounded() {
        #expect(ScriptLauncher.lastLine(of: Data("a\n  b  \n\n".utf8)) == "b")
        #expect(ScriptLauncher.lastLine(of: Data()) == nil)
        let long = String(repeating: "x", count: ScriptLauncher.errorLineLimit + 50)
        #expect(ScriptLauncher.lastLine(of: Data(long.utf8)) == String(repeating: "x", count: ScriptLauncher.errorLineLimit) + "\u{2026}")
    }
}
