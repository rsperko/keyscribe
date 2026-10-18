import Foundation
import Testing
@testable import KeyScribeApp

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

    @Test func aLongRunningScriptIsLeftRunning() async throws {
        let (dir, file) = try script("sleep 5")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ScriptLauncher.run(program: file.path, arguments: [], reportWithin: 0.3) == .stillRunning)
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
