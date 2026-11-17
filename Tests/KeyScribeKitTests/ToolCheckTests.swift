import Foundation
import Testing
@testable import KeyScribeKit

struct ToolCheckTests {
    @Test func aVersionPrintedInTimeIsWorking() {
        #expect(ToolCheck.judge(.exited(0), output: "2.1.326 (Claude Code)\n") == .working("2.1.326"))
        #expect(ToolCheck.judge(.exited(0), output: "pi v1.4.2\n") == .working("1.4.2"))
        #expect(ToolCheck.judge(.exited(0), output: "warning: config moved\n0.49.0\n") == .working("0.49.0"))
    }

    @Test func eachFailureKeepsItsOwnReason() {
        #expect(ToolCheck.judge(.timedOut(10), output: "") == .timedOut(10))
        #expect(ToolCheck.judge(.exited(127), output: "env: node: No such file or directory") == .exited(127, "env: node: No such file or directory"))
        #expect(ToolCheck.judge(.signaled(9), output: "") == .signaled(9))
        #expect(ToolCheck.judge(.exited(0), output: "Usage: claude [options]\n") == .noVersion("Usage: claude [options]"))
        #expect(ToolCheck.judge(.couldNotStart("Permission denied"), output: "") == .couldNotStart("Permission denied"))
    }

    @Test func aFailingExitIsNotWorkingEvenWithAVersion() {
        #expect(ToolCheck.judge(.exited(1), output: "1.2.3 broken") == .exited(1, "1.2.3 broken"))
    }

    @Test func aDateOrSingleNumberIsNotAVersion() {
        #expect(ToolCheck.version(in: "built 2026 ok") == nil)
        #expect(ToolCheck.version(in: "v12") == nil)
        #expect(ToolCheck.version(in: "node 24.1") == "24.1")
    }

    @Test func outputShownWithAFailureIsTrimmedAndBounded() {
        let long = String(repeating: "x", count: 1_000)
        guard case .exited(_, let shown) = ToolCheck.judge(.exited(2), output: "  \n\(long)\n") else {
            Issue.record("expected an exit")
            return
        }
        #expect(shown.count <= ToolCheck.shownOutputLimit + 1)
        #expect(shown.hasSuffix("\u{2026}"))
    }

    @Test func onlyWorkingIsWorking() {
        #expect(ToolCheck.working("1.0.0").isWorking)
        #expect(!ToolCheck.timedOut(10).isWorking)
        #expect(!ToolCheck.noVersion("").isWorking)
    }
}
