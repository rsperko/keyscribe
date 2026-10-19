import ApplicationServices
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct AppWindowsTests {
    private let code = WindowProcess(pid: 20, bundleId: "com.microsoft.VSCode", appName: "Visual Studio Code")
    private let notes = WindowProcess(pid: 21, bundleId: "com.apple.Notes", appName: "Notes")
    private let standard = kAXStandardWindowSubrole as String

    private func listed(_ title: String?, number: CGWindowID? = 1, subrole: String? = nil, minimized: Bool = false) -> ListedWindow {
        ListedWindow(subrole: subrole ?? standard, title: title, number: number, isMinimized: minimized)
    }

    @Test func onlyTitledStandardWindowsWithAStableIdAreTargets() {
        let windows = AppWindows.targets([
            listed("plan.md", number: 7, minimized: true),
            listed("", number: 8),
            listed("   ", number: 9),
            listed("Untitled sheet", number: 10, subrole: kAXDialogSubrole as String),
            listed("No id", number: nil),
        ], of: code)
        #expect(windows == [VoiceCommandCatalog.Window(
            bundleId: code.bundleId, appName: code.appName, pid: 20, id: "cg:7", title: "plan.md", isMinimized: true)])
    }

    @Test func aStableIdSurvivesARenameOrMove() {
        let before = AppWindows.targets([listed("draft.md", number: 7)], of: code)
        let after = AppWindows.targets([listed("final.md", number: 7)], of: code)
        #expect(before.map(\.id) == after.map(\.id))
        #expect(VoiceCommandCandidate.window(before[0]).identity == VoiceCommandCandidate.window(after[0]).identity)
    }

    @Test func aScanCompletesOnlyWhenEveryAppAnswered() {
        let replies: [Int32: AppWindowsReply] = [20: .windows([listed("plan.md", number: 1)]), 21: .windows([])]
        #expect(AppWindows.collect([code, notes], trusted: true, isCurrent: { true }) { replies[$0.pid]! }
                == .complete(AppWindows.targets([listed("plan.md", number: 1)], of: code)))
        #expect(AppWindows.collect([code, notes], trusted: true, isCurrent: { true }) { $0.pid == 21 ? .noResponse : replies[$0.pid]! }
                == .incomplete)
        #expect(AppWindows.collect([code], trusted: true, isCurrent: { true }) { _ in .notTrusted } == .needsAccessibility)
    }

    @Test func anUntrustedProcessReadsNothing() {
        var asked = 0
        #expect(AppWindows.collect([code], trusted: false, isCurrent: { true }) { _ in asked += 1; return .windows([]) }
                == .needsAccessibility)
        #expect(asked == 0)
    }

    @Test func aScanThatStopsBeingWantedIsIncomplete() {
        var current = true
        var asked: [Int32] = []
        let scan = AppWindows.collect([code, notes], trusted: true, isCurrent: { current }) { process in
            asked.append(process.pid)
            current = false
            return .windows([])
        }
        #expect(scan == .incomplete)
        #expect(asked == [20])
    }

    @Test func anAppWithNoWindowsIsDistinctFromAnAppThatDidNotAnswer() {
        #expect(AppWindows.reply(for: .noValue) == .windows([]))
        #expect(AppWindows.reply(for: .attributeUnsupported) == .windows([]))
        #expect(AppWindows.reply(for: .invalidUIElement) == .windows([]))
        #expect(AppWindows.reply(for: .cannotComplete) == .noResponse)
        #expect(AppWindows.reply(for: .failure) == .noResponse)
        #expect(AppWindows.reply(for: .apiDisabled) == .notTrusted)
    }

    private final class Log {
        var steps: [String] = []
    }

    private func steps(_ log: Log, results: [String: WindowStep] = [:], after: @escaping (String) -> Void = { _ in }) -> WindowSteps {
        func step(_ name: String) -> () async -> WindowStep {
            { log.steps.append(name); after(name); return results[name] ?? .done }
        }
        return WindowSteps(
            unhide: step("unhide"), unminimize: step("unminimize"), raise: step("raise"), makeMain: step("main"),
            activate: step("activate"), activateFallback: step("fallback"), confirm: step("confirm"))
    }

    @Test func aWindowIsUnhiddenAndUnminimizedOnlyWhenNeeded() async {
        let plain = Log()
        #expect(await AppWindows.bringForward(isHidden: false, isMinimized: false, steps: steps(plain), stillWanted: { true }) == .focused)
        #expect(plain.steps == ["raise", "main", "activate", "confirm"])
        let tucked = Log()
        #expect(await AppWindows.bringForward(isHidden: true, isMinimized: true, steps: steps(tucked), stillWanted: { true }) == .focused)
        #expect(tucked.steps == ["unhide", "unminimize", "raise", "main", "activate", "confirm"])
    }

    @Test(arguments: ["unhide", "unminimize", "raise", "main", "activate"])
    func noLaterStepRunsOnceTheCommandIsNoLongerWanted(stopAfter: String) async {
        let log = Log()
        var wanted = true
        let result = await AppWindows.bringForward(
            isHidden: true, isMinimized: true, steps: steps(log) { if $0 == stopAfter { wanted = false } },
            stillWanted: { wanted })
        #expect(result == .cancelled)
        #expect(log.steps.last == stopAfter)
        #expect(!log.steps.contains("confirm"))
    }

    @Test func aStepThatFailsStopsTheRest() async {
        let log = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(log, results: ["raise": .noResponse]), stillWanted: { true })
                == .noResponse)
        #expect(log.steps == ["raise"])
        let failed = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: true, steps: steps(failed, results: ["unminimize": .failed]), stillWanted: { true })
                == .failed)
        #expect(failed.steps == ["unminimize"])
    }

    @Test func successNeedsTheChosenWindowToBeTheOneInFront() async {
        let other = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(other, results: ["confirm": .failed]), stillWanted: { true })
                == .failed)
        let silent = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(silent, results: ["confirm": .noResponse]), stillWanted: { true })
                == .noResponse)
    }

    @Test func aMainWindowRequestThatFailsStillLetsTheCheckDecide() async {
        let log = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(log, results: ["main": .failed]), stillWanted: { true })
                == .focused)
        #expect(log.steps == ["raise", "main", "activate", "confirm"])
    }

    @Test func onlyARefusedActivationFallsBackToActivatingTheApp() async {
        let refused = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(refused, results: ["activate": .failed]), stillWanted: { true })
                == .focused)
        #expect(refused.steps == ["raise", "main", "activate", "fallback", "confirm"])
        let unanswered = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(unanswered, results: ["activate": .noResponse]), stillWanted: { true })
                == .noResponse)
        #expect(unanswered.steps == ["raise", "main", "activate"])
    }

    @Test func aFallbackActivationNeedsTheCommandToStillBeWanted() async {
        let log = Log()
        var wanted = true
        let result = await AppWindows.bringForward(
            isHidden: false, isMinimized: false,
            steps: steps(log, results: ["activate": .failed]) { if $0 == "activate" { wanted = false } },
            stillWanted: { wanted })
        #expect(result == .cancelled)
        #expect(!log.steps.contains("fallback"))
    }

    @Test func aFailedFallbackStopsBeforeTheCheck() async {
        let log = Log()
        #expect(await AppWindows.bringForward(
            isHidden: false, isMinimized: false, steps: steps(log, results: ["activate": .failed, "fallback": .noResponse]),
            stillWanted: { true }) == .noResponse)
        #expect(log.steps.last == "fallback")
    }
}
