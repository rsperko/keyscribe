import Foundation
import Testing
@testable import KeyScribeApp

struct HostCLITests {
    private static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hostcli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func gone(_ pid: Int32, within seconds: Double = 2) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func grandchildPid(in file: URL) async -> Int32? {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test func standardOutputAndStandardErrorStaySeparate() async throws {
        let output = try await HostCLI.run(["/bin/sh", "-c", "echo '{\"ok\":true}'; echo warning >&2; exit 3"], subcommand: "list")
        #expect(output.status == 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "{\"ok\":true}\n")
        #expect(output.stderr == "warning\n")
        #expect(!output.truncated)
    }

    @Test func contentGoesThroughStandardInputNotTheArguments() async throws {
        let text = String(repeating: "dictated words; $(rm -rf ~) \"quoted\"\n", count: 5000)
        let output = try await HostCLI.run(["/bin/cat"], subcommand: "tell", input: Data(text.utf8))
        #expect(String(decoding: output.stdout, as: UTF8.self) == text)
    }

    @Test func withoutInputTheProgramReadsNothing() async throws {
        let output = try await HostCLI.run(["/bin/cat"], subcommand: "list", timeout: .seconds(3))
        #expect(output.stdout.isEmpty)
        #expect(output.status == 0)
    }

    @Test func outputPastTheLimitIsDroppedAndMarked() async throws {
        let output = try await HostCLI.run(["/bin/sh", "-c", "head -c 200000 /dev/zero"], subcommand: "show", limit: 1000)
        #expect(output.stdout.count == 1000)
        #expect(output.truncated)
        #expect(output.status == 0)
    }

    @Test func aProgramPastItsDeadlineIsKilledWithEverythingItStarted() async throws {
        let file = Self.scratch().appendingPathComponent("pid")
        let started = Date()
        await #expect(throws: HostCLI.Failure.timedOut("wait")) {
            try await HostCLI.run(
                ["/bin/sh", "-c", "sleep 30 & echo $! > '\(file.path)'; wait"], subcommand: "wait", timeout: .milliseconds(500),
                grace: .milliseconds(200))
        }
        #expect(Date().timeIntervalSince(started) < 5)
        let grandchild = try #require(await Self.grandchildPid(in: file))
        #expect(await Self.gone(grandchild))
    }

    @Test func cancellingTheCallKillsTheProgramAndEverythingItStarted() async throws {
        let file = Self.scratch().appendingPathComponent("pid")
        let task = Task {
            try await HostCLI.run(["/bin/sh", "-c", "sleep 30 & echo $! > '\(file.path)'; wait"], subcommand: "events", timeout: .seconds(30))
        }
        let grandchild = try #require(await Self.grandchildPid(in: file))
        task.cancel()
        await #expect(throws: HostCLI.Failure.cancelled("events")) { try await task.value }
        #expect(await Self.gone(grandchild))
    }

    @Test func aGrandchildHoldingTheOutputOpenDoesNotHoldTheCallPastItsGrace() async throws {
        let started = Date()
        let output = try await HostCLI.run(
            ["/bin/sh", "-c", "echo done; sleep 30 &"], subcommand: "open", timeout: .seconds(10), grace: .milliseconds(300))
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "done\n")
        #expect(output.status == 0)
    }

    @Test func failuresNameTheSubcommandAndNeverTheArguments() async {
        await #expect(throws: HostCLI.Failure.couldNotStart("thread tell")) {
            try await HostCLI.run(["/nonexistent/bb", "thread", "tell", "secret dictation"], subcommand: "thread tell")
        }
        await #expect(throws: HostCLI.Failure.couldNotStart("ls")) {
            try await HostCLI.run(["relative/rex", "ls"], subcommand: "ls")
        }
        #expect(!HostCLI.Failure.timedOut("thread tell").description.contains("secret"))
        #expect(HostCLI.Failure.timedOut("thread tell").description == "thread tell did not finish in time")
    }

    @Test func onlyTheGivenEnvironmentReachesTheProgram() async throws {
        let output = try await HostCLI.run(["/usr/bin/env"], subcommand: "env", environment: ["ONLY": "this"])
        #expect(String(decoding: output.stdout, as: UTF8.self) == "ONLY=this\n")
    }
}
