import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct BBHostTests {
    final class Runner: @unchecked Sendable {
        var answers: [String: Result<HostCLI.Output, HostCLI.Failure>] = [:]
        var answersOnlyOnceCancelled = false
        var calls: [(argv: [String], input: String?, environment: [String: String])] = []

        func run(_ argv: [String], subcommand: String, input: Data?, environment: [String: String]) async throws -> HostCLI.Output {
            calls.append((argv, input.map { String(decoding: $0, as: UTF8.self) }, environment))
            if answersOnlyOnceCancelled { try? await Task.sleep(for: .seconds(30)) }
            switch answers[subcommand] ?? .failure(.couldNotStart(subcommand)) {
            case .success(let output): return output
            case .failure(let failure): throw failure
            }
        }
    }

    static func output(_ json: String, status: Int32 = 0) -> Result<HostCLI.Output, HostCLI.Failure> {
        .success(HostCLI.Output(status: status, stdout: Data(json.utf8), stderr: "", truncated: false))
    }

    static let home = "/Users/a"
    static let cli = "/Users/a/.bb/bin/bb"
    static let location = AgentHostLocation(host: "bb", instance: "/Users/a/.bb", native: "thr_abc1")
    static let bundle = "dev.bb.desktop"

    static func seen(_ app: AgentHostApp, _ folder: String) -> AgentHostApp {
        var seen = app
        seen.instance = folder
        return seen
    }
    static let usual = BBBuild(folder: "/Users/a/.bb", app: "/Applications/bb.app", bundle: bundle, name: "bb")
    static let acme = BBBuild(folder: "/Users/a/.acme-bb", app: "/Applications/bb (Acme).app", bundle: "com.example.acme-bb", name: "bb (Acme)")

    private func host(
        _ runner: Runner, installed: Bool = true, running: Bool = true, frontmost: @escaping @MainActor () -> AgentHostApp? = { nil }
    ) -> (BBHost, () -> Int) {
        let (host, activated) = host(runner, builds: [Self.usual], installed: installed, open: { _ in running }, frontmost: frontmost)
        return (host, { activated().count })
    }

    private func host(
        _ runner: Runner, builds: [BBBuild], enrolled: [String]? = nil, installed: Bool = true,
        open: @escaping @MainActor (BBBuild) -> Bool = { _ in true }, frontmost: @escaping @MainActor () -> AgentHostApp? = { nil },
        frontApp: (@MainActor () -> AgentHostApp?)? = nil, dataFolders: [String: String] = [:]
    ) -> (BBHost, () -> [String]) {
        var activations: [String] = []
        let host = BBHost(
            home: Self.home, enrolled: { enrolled ?? builds.map(\.folder) }, describe: { folder in builds.first { $0.folder == folder } },
            installed: { path in installed && builds.contains { $0.launcher == path } }, isOpen: open,
            run: { try await runner.run($0, subcommand: $1, input: $2, environment: $3) },
            activate: { activations.append($0.folder) }, frontmost: { _ in frontmost() },
            frontApp: frontApp ?? { frontmost().map { AgentHostApp(bundle: $0.bundle, pid: $0.pid, name: $0.name, path: $0.path) } },
            dataFolder: { dataFolders[$0] })
        return (host, { activations })
    }

    @Test func aNameTheUserGivesAThreadBecomesItsBbTitle() async {
        let runner = Runner()
        runner.answers["thread update"] = Self.output(#"{"id":"thr_abc1","title":"-docs fix"}"#)
        #expect(await host(runner).0.rename(Self.location, to: "-docs fix"))
        #expect(runner.calls.map(\.argv) == [[Self.cli, "thread", "update", "thr_abc1", "--title=-docs fix", "--json"]])
    }

    @Test func aThreadIsRetitledOnlyWhileBbIsOpenAndListsIt() async {
        let runner = Runner()
        runner.answers["thread update"] = Self.output("{}", status: 1)
        #expect(await !host(runner).0.rename(Self.location, to: "docs"))
        #expect(await !host(runner, running: false).0.rename(Self.location, to: "docs"))
        let elsewhere = AgentHostLocation(host: "bb", instance: "/Users/b/.bb", native: "thr_abc1")
        #expect(await !host(runner).0.rename(elsewhere, to: "docs"))
        #expect(await !host(Runner()).0.rename(Self.location, to: "docs"))
        #expect(runner.calls.count == 1)
    }

    @Test func bbIsAvailableOnlyWhileItsCommandIsInstalled() {
        #expect(host(Runner()).0.isEnabled)
        #expect(!host(Runner(), installed: false).0.isEnabled)
    }

    @Test func everyCallRunsTheInstalledCommandWithTelemetryOffAndAFixedEnvironment() async {
        let runner = Runner()
        runner.answers["thread list"] = Self.output("[]")
        _ = await host(runner).0.scan()
        let call = try! #require(runner.calls.first)
        #expect(call.argv == [Self.cli, "thread", "list", "--json"])
        #expect(call.environment == [
            "HOME": Self.home, "PATH": "/usr/bin:/bin", "BB_TELEMETRY": "false", "BB_DATA_DIR": "/Users/a/.bb",
        ])
    }

    @Test func everyCallReachesTheServerItsDataFolderRecords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bbserver-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"entryPath":"/nix/store/x/bb-app.js","pid":\#(getpid()),"serverUrl":"http://127.0.0.1:4411"}"#.utf8)
            .write(to: folder.appendingPathComponent(BBBuilds.runtimeFile))
        let runner = Runner()
        runner.answers["thread list"] = Self.output("[]")
        let build = BBBuild(folder: folder.path, app: "/Applications/bb Work.app", bundle: "com.example.bb-work", name: "bb Work")
        _ = await host(runner, builds: [build]).0.scan()
        #expect(runner.calls.first?.environment["BB_SERVER_URL"] == "http://127.0.0.1:4411")
        #expect(runner.calls.first?.environment["BB_DATA_DIR"] == folder.path)
    }

    @Test func threadsAreListedAsHostedConversationsOfThisBBEachLabelledWithTheTitleBbShows() async {
        let runner = Runner()
        runner.answers["thread list"] = Self.output("""
            [{"id":"thr_abc1","title":"ks-probe pi","titleFallback":"Reply with ready","status":"active","visibility":"visible",
              "archivedAt":null,"deletedAt":null,"environmentPath":"/src/app","hasPendingInteraction":false,"createdAt":1794629582057},
             {"id":"thr_abc2","title":null,"titleFallback":"Reply with ready","status":"idle","visibility":"visible",
              "archivedAt":null,"deletedAt":null,"environmentPath":"/src/app","hasPendingInteraction":false,"createdAt":1794629582058}]
            """)
        let second = AgentHostLocation(host: "bb", instance: "/Users/a/.bb", native: "thr_abc2")
        #expect(await host(runner).0.scan() == .found(
            [
                AgentSession(agent: "bb", id: "thr_abc1", pid: nil, cwd: "/src/app", state: .working, startedAt: 1794629582057, host: Self.location),
                AgentSession(agent: "bb", id: "thr_abc2", pid: nil, cwd: "/src/app", state: .idle, startedAt: 1794629582058, host: second),
            ],
            titles: [Self.location.conversationKey: "ks-probe pi"], shownInstead: [second.conversationKey: "Reply with ready"]))
    }

    @Test func aListThatCannotBeReadIsUnreadableNotEmptyAndSaysWhatToTry() async {
        let runner = Runner()
        let unreadable = AgentHostScan.unreadable("bb could not list its threads. Try again in a moment.")
        #expect(await host(runner).0.scan() == unreadable)
        runner.answers["thread list"] = Self.output(#"{"ok":false,"error":{"code":"error","message":"down"}}"#, status: 1)
        #expect(await host(runner).0.scan() == unreadable)
        runner.answers["thread list"] = .failure(.timedOut("thread list"))
        #expect(await host(runner).0.scan() == unreadable)
    }

    @Test func whileBBIsNotOpenItsCommandIsNeverRun() async {
        let runner = Runner()
        runner.answers["thread list"] = Self.output("[]")
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"sent"}"#)
        runner.answers["thread open"] = Self.output(#"{"delivered":1}"#)
        let (bb, activations) = host(runner, running: false)
        #expect(await bb.scan() == .unreadable("bb isn\u{2019}t open. Open bb to reach its threads."))
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .refused("bb isn\u{2019}t open."))
        #expect(await bb.open(Self.location, stillWanted: { true }) == .failed)
        #expect(runner.calls.isEmpty)
        #expect(activations() == 0)
    }

    @Test func anAgentBBStartedIsPlacedInItsThreadOfThisBBByItsEnvironmentAlone() async {
        let runner = Runner()
        let bb = host(runner, running: false).0
        #expect(bb.identityKeys == ["BB_THREAD_ID", "BB_THREAD_STORAGE"])
        let environment = ["BB_THREAD_ID": "thr_abc1", "BB_THREAD_STORAGE": "/Users/a/.bb/thread-storage/thr_abc1"]
        #expect(bb.location(in: environment) == Self.location)
        #expect(bb.location(in: ["BB_THREAD_ID": "thr_abc1", "BB_THREAD_STORAGE": "/Users/b/.bb/thread-storage/thr_abc1"]) == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func bbTakesImages() {
        #expect(host(Runner()).0.takesImages)
    }

    @Test func dictationIsQueuedBehindARunningTurnAndCarriedOnStandardInput() async {
        let runner = Runner()
        runner.answers["thread tell"] = Self.output(#"{"threadId":"thr_abc1","ok":true,"delivery":"sent","mode":"queue"}"#)
        let delivered = await host(runner).0.deliver("run the tests; $(rm -rf ~)", images: [], request: "r1", to: Self.location)
        #expect(delivered == .accepted)
        let call = try! #require(runner.calls.first)
        #expect(call.argv == [Self.cli, "thread", "tell", "thr_abc1", "--message-file", "-", "--mode", "auto", "--json"])
        #expect(call.input == "run the tests; $(rm -rf ~)")
    }

    @Test func clipboardImagesAreAttachedToTheMessage() async {
        let runner = Runner()
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"sent"}"#)
        _ = await host(runner).0.deliver("see /tmp/a.png and /tmp/b.png", images: ["/tmp/a.png", "/tmp/b.png"], request: "r1", to: Self.location)
        #expect(runner.calls.first?.argv == [
            Self.cli, "thread", "tell", "thr_abc1", "--message-file", "-", "--mode", "auto", "--json", "--image", "/tmp/a.png", "--image", "/tmp/b.png",
        ])
    }

    @Test func eachAnswerFromBBMapsToWhatItProves() async {
        let runner = Runner()
        let (bb, _) = host(runner)
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"queued"}"#)
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .queued)
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"something-new"}"#)
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .uncertain)
        runner.answers["thread tell"] = Self.output(#"{"ok":false,"error":{"code":"thread_not_found","message":"HTTP 404: Thread not found"}}"#, status: 1)
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .refused("bb no longer has this thread."))
        runner.answers["thread tell"] = .failure(.timedOut("thread tell"))
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .uncertain)
        runner.answers["thread tell"] = .failure(.cancelled("thread tell"))
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .uncertain)
        runner.answers["thread tell"] = .failure(.couldNotStart("thread tell"))
        #expect(await bb.deliver("x", images: [], request: "r", to: Self.location) == .refused("bb could not start."))
        #expect(runner.calls.count == 6)
    }

    @Test func aLocationThatIsNotThisBBsThreadIsNeverPassedToIt() async {
        let runner = Runner()
        let (bb, _) = host(runner)
        let other = AgentHostLocation(host: "bb", instance: "/elsewhere/.bb", native: "thr_abc1")
        let odd = AgentHostLocation(host: "bb", instance: "/Users/a/.bb", native: "--split")
        #expect(await bb.deliver("x", images: [], request: "r", to: other) == .refused("bb no longer lists this thread."))
        #expect(await bb.deliver("x", images: [], request: "r", to: odd) == .refused("bb no longer lists this thread."))
        #expect(await bb.open(other, stillWanted: { true }) == .failed)
        #expect(runner.calls.isEmpty)
    }

    @Test func openAsksBBsWindowsToShowTheThreadThenBringsBBForwardButClaimsOnlyAsking() async {
        let runner = Runner()
        runner.answers["thread open"] = Self.output(#"{"threadId":"thr_abc1","split":"replace","delivered":2}"#)
        let (bb, activations) = host(runner)
        #expect(await bb.open(Self.location, stillWanted: { true }) == .requested)
        #expect(runner.calls.first?.argv == [Self.cli, "thread", "open", "thr_abc1", "--json"])
        #expect(activations() == 1)
    }

    @Test func openWithNoBBWindowOrNoAnswerIsNotOpened() async {
        let runner = Runner()
        let (bb, activations) = host(runner)
        runner.answers["thread open"] = Self.output(#"{"threadId":"thr_abc1","delivered":0}"#)
        #expect(await bb.open(Self.location, stillWanted: { true }) == .failed)
        runner.answers["thread open"] = .failure(.timedOut("thread open"))
        #expect(await bb.open(Self.location, stillWanted: { true }) == .failed)
        #expect(activations() == 0)
    }

    @Test func openNoLongerWantedWhenBBAnswersNeverBringsBBForward() async {
        let runner = Runner()
        runner.answers["thread open"] = Self.output(#"{"delivered":1}"#)
        let (bb, activations) = host(runner)
        #expect(await bb.open(Self.location, stillWanted: { false }) == .failed)
        #expect(activations() == 0)
    }

    @Test func openCancelledWhileBBsCommandRunsNeverBringsBBForwardEvenIfTheCommandFinishes() async {
        let runner = Runner()
        runner.answers["thread open"] = Self.output(#"{"delivered":1}"#)
        runner.answersOnlyOnceCancelled = true
        let (bb, activations) = host(runner)
        let open = Task { await bb.open(Self.location, stillWanted: { true }) }
        for _ in 0..<100 where runner.calls.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        open.cancel()
        #expect(await open.value == .failed)
        #expect(activations() == 0)
    }

    @Test func theThreadInFrontIsTheOneThePluginLastSaidBbShowsAndOnlyWhileBbIsTheAppInFront() async {
        let bb = AgentHostApp(bundle: Self.bundle, pid: 31, name: "bb", window: "cg:4")
        let other = AgentHostApp(bundle: "com.apple.Safari", pid: 32, name: "Safari")
        var front: AgentHostApp? = bb
        let (host, _) = host(Runner(), frontmost: { front })
        let elsewhere = AgentHostLocation(host: "bb", instance: "/Users/a/.bb", native: "thr_other")
        #expect(await host.front(among: [Self.location], reported: Self.location, in: host.focusedWindow()) == .shown(Self.location, in: Self.seen(bb, Self.usual.folder)))
        #expect(await host.front(among: [Self.location], reported: nil, in: host.focusedWindow()) == .unknown)
        #expect(await host.front(among: [Self.location], reported: elsewhere, in: host.focusedWindow()) == .unknown)
        front = other
        #expect(await host.front(among: [Self.location], reported: Self.location, in: host.focusedWindow()) == .unknown)
        front = nil
        #expect(await host.front(among: [Self.location], reported: Self.location, in: host.focusedWindow()) == .unknown)
        front = AgentHostApp(bundle: Self.bundle, pid: 31, name: "bb")
        #expect(await host.front(among: [Self.location], reported: Self.location, in: host.focusedWindow()) == .unknown)
    }

    @Test func aRebrandedBuildIsDrivenThroughItsOwnCommandAndDataFolderAndNamedAsItIsCalled() async {
        let runner = Runner()
        runner.answers["thread list"] = Self.output("[]")
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"sent"}"#)
        let (bb, _) = host(runner, builds: [Self.acme])
        #expect(bb.isEnabled)
        #expect(await bb.scan() == .found([]))
        let thread = AgentHostLocation(host: "bb", instance: Self.acme.folder, native: "thr_abc1")
        #expect(await bb.deliver("x", images: [], request: "r", to: thread) == .accepted)
        #expect(runner.calls.map { $0.argv.first } == [Self.acme.launcher, Self.acme.launcher])
        #expect(runner.calls.allSatisfy { $0.environment["BB_DATA_DIR"] == Self.acme.folder })
        let environment = ["BB_THREAD_ID": "thr_abc1", "BB_THREAD_STORAGE": "/Users/a/.acme-bb/thread-storage/thr_abc1"]
        #expect(bb.location(in: environment) == thread)
        let (closed, _) = host(Runner(), builds: [Self.acme], open: { _ in false })
        #expect(await closed.scan() == .unreadable("bb (Acme) isn\u{2019}t open. Open bb (Acme) to reach its threads."))
        #expect(await closed.deliver("x", images: [], request: "r", to: thread) == .refused("bb (Acme) isn\u{2019}t open."))
    }

    @Test func twoBuildsSideBySideEachListTheirOwnThreadsAndEachThreadGoesToItsOwnBuild() async {
        let runner = Runner()
        runner.answers["thread list"] = Self.output(#"[{"id":"thr_abc1","status":"idle","visibility":"visible","environmentPath":"/src"}]"#)
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"sent"}"#)
        runner.answers["thread open"] = Self.output(#"{"delivered":1}"#)
        var acmeOpen = true
        let (bb, activated) = host(runner, builds: [Self.usual, Self.acme], open: { $0 == Self.usual || acmeOpen })
        let mine = Self.location
        let theirs = AgentHostLocation(host: "bb", instance: Self.acme.folder, native: "thr_abc1")
        guard case .found(let sessions, _, _, let carried, let problem) = await bb.scan() else { Issue.record("expected threads"); return }
        #expect(sessions.compactMap(\.host) == [mine, theirs])
        #expect(carried.isEmpty && problem == nil)
        runner.answers["thread list"] = Self.output("[]")
        acmeOpen = false
        guard case .found(let kept, _, _, let carriedNow, let problemNow) = await bb.scan() else { Issue.record("expected threads"); return }
        #expect(kept.compactMap(\.host) == [theirs])
        #expect(carriedNow == [theirs])
        #expect(problemNow == "bb (Acme) isn\u{2019}t open. Open bb (Acme) to reach its threads.")
        acmeOpen = true
        runner.calls.removeAll()
        #expect(await bb.deliver("x", images: [], request: "r", to: theirs) == .accepted)
        #expect(await bb.open(mine, stillWanted: { true }) == .requested)
        #expect(runner.calls.map { $0.argv.first } == [Self.acme.launcher, Self.usual.launcher])
        #expect(activated() == [Self.usual.folder])
    }

    @Test func aThreadIsInFrontOnlyWhileItsOwnBuildIsTheAppInFront() async {
        let acme = AgentHostApp(bundle: Self.acme.bundle!, pid: 41, name: "bb (Acme)", window: "cg:7")
        let (bb, _) = host(Runner(), builds: [Self.usual, Self.acme], frontmost: { acme })
        let theirs = AgentHostLocation(host: "bb", instance: Self.acme.folder, native: "thr_abc1")
        #expect(await bb.front(among: [Self.location, theirs], reported: theirs, in: bb.focusedWindow()) == .shown(theirs, in: Self.seen(acme, Self.acme.folder)))
        #expect(await bb.front(among: [Self.location, theirs], reported: Self.location, in: bb.focusedWindow()) == .unknown)
        #expect(bb.focusedWindow()?.instance == Self.acme.folder)
    }

    @Test func aBuildNotConnectedIsNeverRun() async {
        let runner = Runner()
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"sent"}"#)
        let (bb, _) = host(runner, builds: [Self.usual])
        let theirs = AgentHostLocation(host: "bb", instance: Self.acme.folder, native: "thr_abc1")
        #expect(await bb.deliver("x", images: [], request: "r", to: theirs) == .refused("bb no longer lists this thread."))
        #expect(runner.calls.isEmpty)
    }

    static let work = BBBuild(folder: "/Users/a/.work-bb", app: "/Applications/bb Work.app", bundle: bundle, name: "bb Work")

    @Test func twoCopiesOfOneAppAreToldApartByWhereEachIsInstalled() async {
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: Self.work.app)
        let (bb, _) = host(Runner(), builds: [Self.usual, Self.work], frontmost: { front })
        let theirs = AgentHostLocation(host: "bb", instance: Self.work.folder, native: "thr_abc1")
        #expect(await bb.front(among: [Self.location, theirs], reported: Self.location, in: bb.focusedWindow()) == .unknown)
        #expect(await bb.front(among: [Self.location, theirs], reported: theirs, in: bb.focusedWindow()) == .shown(theirs, in: Self.seen(front, Self.work.folder)))
        #expect(bb.focusedWindow()?.instance == Self.work.folder)
    }

    @Test func aCopyOfBbInFrontIsNamedByItsAppAndSaysWhetherThePluginIsInstalledForIt() async {
        var front: AgentHostApp? = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: Self.work.app)
        let (bb, _) = host(
            Runner(), builds: [Self.usual, Self.work], enrolled: [Self.usual.folder], frontmost: { front },
            dataFolders: [Self.work.app!: Self.work.folder])
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb Work", instance: Self.work.folder, enrolled: false))
        front = AgentHostApp(bundle: Self.bundle, pid: 42, name: "bb", window: "cg:8", path: Self.usual.app)
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb", instance: Self.usual.folder, enrolled: true))
        front = AgentHostApp(bundle: "com.apple.Safari", pid: 32, name: "Safari", window: "cg:9", path: "/Applications/Safari.app")
        #expect(bb.copyInFront() == nil)
        front = nil
        #expect(bb.copyInFront() == nil)
    }

    @Test func aCopyWhoseRecordedAppPathIsStaleIsStillFoundByTheDataFolderItsAppUses() async {
        let moved = BBBuild(folder: Self.usual.folder, app: "/Applications/Old/bb.app", bundle: Self.bundle, name: "bb")
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: "/Applications/bb.app")
        let (bb, _) = host(Runner(), builds: [moved], frontmost: { front })
        #expect(await bb.front(among: [Self.location], reported: Self.location, in: bb.focusedWindow()) == .shown(Self.location, in: Self.seen(front, Self.usual.folder)))
        #expect(bb.focusedWindow()?.instance == Self.usual.folder)
        #expect(bb.copyInFront()?.enrolled == true)
    }

    @Test func aCopyWithoutThePluginIsNeverTakenForAnotherCopyOfTheSameAppThatHasIt() async {
        let moved = BBBuild(folder: Self.usual.folder, app: "/Applications/Old/bb.app", bundle: Self.bundle, name: "bb")
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: Self.work.app)
        let (bb, _) = host(
            Runner(), builds: [moved, Self.work], enrolled: [moved.folder], frontmost: { front }, dataFolders: [Self.work.app!: Self.work.folder])
        #expect(await bb.front(among: [Self.location], reported: Self.location, in: bb.focusedWindow()) == .unknown)
        #expect(bb.focusedWindow() == nil)
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb Work", instance: Self.work.folder, enrolled: false))
    }

    @Test func aCopyWhoseAppOpenedAfterItsFolderWasLastDescribedIsFoundInFront() async {
        final class Described: @unchecked Sendable {
            var build: BBBuild
            init(_ build: BBBuild) { self.build = build }
        }
        let work = Self.work
        let described = Described(BBBuild(folder: work.folder, name: BBBuilds.fallbackName))
        var front: AgentHostApp?
        let bb = BBHost(
            home: Self.home, enrolled: { [work.folder] }, describe: { $0 == work.folder ? described.build : nil }, installed: { _ in true },
            isOpen: { _ in true }, run: { _, _, _, _ in throw HostCLI.Failure.couldNotStart("") }, activate: { _ in },
            frontmost: { _ in front }, frontApp: { front.map { AgentHostApp(bundle: $0.bundle, pid: $0.pid, name: $0.name, path: $0.path) } },
            dataFolder: { $0 == work.app ? work.folder : nil })
        #expect(bb.focusedWindow() == nil)
        described.build = work
        front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: work.app)
        #expect(bb.focusedWindow()?.instance == work.folder)
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb Work", instance: work.folder, enrolled: true))
    }

    @Test func anAppThatDeclaresAFolderBbHasNotSetUpIsStillNamedWhenItIsInFront() async {
        let front = AgentHostApp(bundle: "com.example.bb-new", pid: 41, name: "bb", window: "cg:7", path: "/Applications/bb New.app")
        let (bb, _) = host(Runner(), builds: [Self.usual], frontmost: { front }, dataFolders: [front.path!: "/Users/a/.bb-new"])
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb New", instance: "/Users/a/.bb-new", enrolled: false, setUp: false))
        #expect(bb.focusedWindow() == nil)
    }

    @Test func anotherAppThatDeclaresTheSameFolderIsThatCopyToo() async {
        let other = AgentHostApp(bundle: "com.example.bb-work-2", pid: 52, name: "bb", window: "cg:9", path: "/Applications/bb Work 2.app")
        let (bb, _) = host(Runner(), builds: [Self.usual, Self.work], frontmost: { other }, dataFolders: [other.path!: Self.work.folder])
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb Work 2", instance: Self.work.folder, enrolled: true))
        #expect(bb.focusedWindow()?.instance == Self.work.folder)
    }

    @Test func aDeclaringAppWhoseFolderGetsSetUpWhileItIsInFrontIsFoundWithoutARefresh() async {
        final class Described: @unchecked Sendable {
            var build: BBBuild?
        }
        let described = Described()
        let work = Self.work
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: work.app)
        let bb = BBHost(
            home: Self.home, enrolled: { [work.folder] }, describe: { $0 == work.folder ? described.build : nil }, installed: { _ in true },
            isOpen: { _ in true }, run: { _, _, _, _ in throw HostCLI.Failure.couldNotStart("") }, activate: { _ in },
            frontmost: { _ in front }, frontApp: { AgentHostApp(bundle: front.bundle, pid: front.pid, name: front.name, path: front.path) },
            dataFolder: { $0 == work.app ? work.folder : nil })
        #expect(bb.copyInFront()?.setUp == false)
        described.build = work
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb Work", instance: work.folder, enrolled: true))
        #expect(bb.focusedWindow()?.instance == work.folder)
    }

    final class Apps: @unchecked Sendable {
        var changed: (@MainActor (String, Bool) -> Void)?
        var watches = 0
        var cancelled = 0
    }

    @MainActor final class Changes {
        var count = 0
    }

    static func within(_ limit: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func watched(
        _ apps: Apps, builds: [BBBuild], run: @escaping BBHost.Run = { _, _, _, _ in throw HostCLI.Failure.couldNotStart("") },
        dataFolders: [String: String] = [:], retries: Int = 8
    ) -> BBHost {
        BBHost(
            home: Self.home, enrolled: { builds.map(\.folder) + dataFolders.values }, describe: { folder in builds.first { $0.folder == folder } },
            installed: { _ in true }, isOpen: { _ in true }, run: run, activate: { _ in },
            frontmost: { _ in nil }, frontApp: { nil }, dataFolder: { dataFolders[$0] },
            appsChanging: {
                apps.changed = $0
                apps.watches += 1
                return { apps.cancelled += 1 }
            },
            launchRetries: retries, launchRetryDelay: .milliseconds(1))
    }

    @Test func aCopyOfBbLaunchingOrQuittingTellsTheHubItsListChanged() async {
        let apps = Apps()
        let lab = "/Applications/bb Lab.app"
        let bb = watched(apps, builds: [Self.work], dataFolders: [lab: "/Users/a/.bb-lab"])
        let changes = Changes()
        bb.watch { changes.count += 1 }
        apps.changed?(Self.work.app!, false)
        apps.changed?(lab, false)
        apps.changed?("/Applications/Safari.app", true)
        #expect(changes.count == 2)
    }

    @Test func aCopyThatLaunchedIsScannedAgainUntilItListsWhileTheOtherCopiesListFine() async {
        final class Lists: @unchecked Sendable { var failing = 1 }
        let lists = Lists()
        let apps = Apps()
        let work = Self.work
        let bb = watched(apps, builds: [Self.usual, work], run: { _, _, _, environment in
            if environment["BB_DATA_DIR"] == work.folder, lists.failing > 0 {
                lists.failing -= 1
                throw HostCLI.Failure.couldNotStart("")
            }
            return HostCLI.Output(status: 0, stdout: Data("[]".utf8), stderr: "", truncated: false)
        })
        let changes = Changes()
        bb.watch { changes.count += 1 }
        apps.changed?(work.app!, true)
        #expect(changes.count == 1)
        guard case .found(_, _, _, _, let problem) = await bb.scan() else { Issue.record("expected a listing"); return }
        #expect(problem == "bb Work could not list its threads. Try again in a moment.")
        #expect(await Self.within { changes.count == 2 })
        guard case .found(_, _, _, _, nil) = await bb.scan() else { Issue.record("expected every copy listed"); return }
        lists.failing = 1
        _ = await bb.scan()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(changes.count == 2)
    }

    @Test func aCopyThatNeverListsAfterLaunchingIsRetriedOnlyABoundedNumberOfTimes() async {
        let apps = Apps()
        let bb = watched(apps, builds: [Self.usual, Self.work], retries: 2)
        let changes = Changes()
        bb.watch { changes.count += 1 }
        apps.changed?(Self.work.app!, true)
        _ = await bb.scan()
        #expect(await Self.within { changes.count == 2 })
        _ = await bb.scan()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(changes.count == 2)
    }

    @Test func watchingAgainOrStoppingRemovesTheEarlierObservers() {
        let apps = Apps()
        let bb = watched(apps, builds: [Self.work])
        bb.watch {}
        bb.watch {}
        #expect(apps.watches == 2)
        #expect(apps.cancelled == 1)
        bb.unwatch()
        #expect(apps.cancelled == 2)
        bb.unwatch()
        #expect(apps.cancelled == 2)
    }

    @Test func aFolderNoAppIsKnownToUseSaysSoRatherThanThatBbIsNotOpen() async {
        let runner = Runner()
        let orphan = BBBuild(folder: "/Users/a/.work-bb", name: BBBuilds.fallbackName)
        let (bb, _) = host(runner, builds: [orphan], open: { _ in false })
        #expect(await bb.scan() == .unreadable(
            "Open the copy of bb that uses ~/.work-bb to reach its threads. "
                + "If it\u{2019}s already open, \(Branding.appName) can\u{2019}t tell that it uses this folder."))
        #expect(runner.calls.isEmpty)
    }

    @Test func aCopyWhoseDataFolderWasAddedByHandIsNamedWhenItIsInFront() async {
        let added = BBBuild(folder: "/srv/bb", app: "/Applications/bb Lab.app", bundle: Self.bundle, name: "bb Lab")
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: added.app)
        let (bb, _) = host(Runner(), builds: [added], frontmost: { front })
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb Lab", instance: added.folder, enrolled: true))
    }

    @Test func aSymlinkedUsualDataFolderIsTheSameCopyAsTheFolderItPointsTo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bblink-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real-bb", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".bb"), withDestinationURL: real)
        let folder = ConnectorFolders.canonical(real).path
        let build = BBBuild(folder: folder, app: "/Applications/Old/bb.app", bundle: Self.bundle, name: "bb")
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: "/Applications/bb.app")
        let bb = BBHost(
            home: root.path, enrolled: { [folder] }, describe: { $0 == folder ? build : nil }, installed: { _ in true }, isOpen: { _ in true },
            run: { _, _, _, _ in throw HostCLI.Failure.couldNotStart("") }, activate: { _ in }, frontmost: { _ in front },
            frontApp: { front }, dataFolder: { _ in nil })
        #expect(bb.copyInFront() == AgentHostCopy(name: "bb", instance: folder, enrolled: true))
    }

    @Test func tellingWhichCopyIsInFrontNeverReadsItsWindow() async {
        var reads = 0
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: Self.usual.app)
        let usual = Self.usual
        let bb = BBHost(
            home: Self.home, enrolled: { [usual.folder] }, describe: { $0 == usual.folder ? usual : nil }, installed: { _ in true },
            isOpen: { _ in true }, run: { _, _, _, _ in throw HostCLI.Failure.couldNotStart("") }, activate: { _ in },
            frontmost: { _ in
                reads += 1
                return front
            },
            frontApp: { AgentHostApp(bundle: front.bundle, pid: front.pid, name: front.name, path: front.path) }, dataFolder: { _ in nil })
        #expect(bb.copyInFront()?.instance == Self.usual.folder)
        #expect(reads == 0)
    }

    @Test func whichThreadIsInFrontIsDecidedFromTheReadingItIsGivenWithoutReadingBbsWindowAgain() async {
        var reads = 0
        let front = AgentHostApp(bundle: Self.bundle, pid: 41, name: "bb", window: "cg:7", path: Self.usual.app)
        let (bb, _) = host(
            Runner(), builds: [Self.usual],
            frontmost: {
                reads += 1
                return front
            },
            frontApp: { AgentHostApp(bundle: front.bundle, pid: front.pid, name: front.name, path: front.path) })
        let reading = bb.focusedWindow()
        #expect(reads == 1)
        #expect(await bb.front(among: [Self.location], reported: Self.location, in: reading) == .shown(Self.location, in: Self.seen(front, Self.usual.folder)))
        #expect(await bb.front(among: [Self.location], reported: Self.location, in: nil) == .unknown)
        #expect(reads == 1)
    }

    @Test func bbsWindowIsFocusedOnlyWhileBbIsTheAppInFrontWithAWindowFocused() {
        let bb = AgentHostApp(bundle: Self.bundle, pid: 31, name: "bb", window: "cg:4")
        var front: AgentHostApp? = bb
        let (host, _) = host(Runner(), frontmost: { front })
        #expect(host.focusedWindow()?.pid == bb.pid)
        front = AgentHostApp(bundle: "com.apple.Safari", pid: 32, name: "Safari", window: "cg:9")
        #expect(host.focusedWindow() == nil)
        front = AgentHostApp(bundle: Self.bundle, pid: 31, name: "bb")
        #expect(host.focusedWindow() == nil)
        front = nil
        #expect(host.focusedWindow() == nil)
    }
}

@MainActor
struct AgentHostConsentModelTests {
    @Test func turningAHostOnOrOffReportsTheWholeListOnceAndLoadingReportsNothing() {
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: FileManager.default.temporaryDirectory, connectors: [], hosts: [BBHost.kind])
        var reported: [[String]] = []
        model.onHostsChange = { reported.append($0) }
        model.load(hosts: ["other"])
        #expect(!model.isTurnedOn(BBHost.kind))
        model.setTurnedOn(BBHost.kind, true)
        model.setTurnedOn(BBHost.kind, true)
        #expect(model.isTurnedOn(BBHost.kind))
        model.setTurnedOn(BBHost.kind, false)
        #expect(reported == [["other", "bb"], ["other"]])
    }

    private func pluginModel(_ calls: BBPluginConnectorTests.Calls) -> (AgentsSettingsModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bbconsent-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".bb/bin"), withIntermediateDirectories: true)
        let agents = root.appendingPathComponent("agents", isDirectory: true)
        let plugin = BBPluginConnector(
            agentsDir: agents, pluginName: "keyscribe-dev", home: home, sources: BBPluginConnectorTests.sources, isExecutable: { _ in true },
            run: { argv, subcommand, _, environment in
                calls.record(argv, environment)
                return calls.answer(subcommand)
            }, find: { [] })
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: agents, setups: ConnectorSetupRegistry(directory: agents), connectors: [plugin],
            hosts: [BBHost.kind])
        return (model, agents)
    }

    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    private func pluginSetup(_ model: AgentsSettingsModel) throws -> (AgentConnectorModel, ConnectorSetupModel) {
        let connector = try #require(model.connectors.first)
        let setup = try #require(connector.setups.first { $0.isDefault })
        return (connector, setup)
    }

    private func installed(_ calls: BBPluginConnectorTests.Calls) -> (AgentsSettingsModel, ConnectorSetupModel, URL) {
        let (model, agents) = pluginModel(calls)
        let setup = model.connectors[0].setups.first { $0.isDefault }!
        return (model, setup, agents)
    }

    private static let listed = #"{"plugins":[{"id":"keyscribe-dev","enabled":true,"status":"running","source":"path:AGENTS/bb-plugin"}]}"#

    @Test func installingAHostsPluginAsksOnceInTheHostsOwnWordsThenConnectsIt() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let (model, agents) = pluginModel(calls)
        var reported: [[String]] = []
        model.onHostsChange = { reported.append($0) }
        let (connector, setup) = try pluginSetup(model)
        model.requestInstall(setup, of: connector)
        let request = try #require(model.consent)
        #expect(model.host(of: request.connector) == BBHost.kind)
        #expect(!model.isTurnedOn(BBHost.kind))
        #expect(calls.all.isEmpty)
        model.confirm(request)
        #expect(await settled { calls.all.contains { $0.0.contains("install") } && setup.operation == nil })
        #expect(model.isTurnedOn(BBHost.kind))
        #expect(model.isTurnedOn(id: "bb"))
        #expect(reported.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent("bb-plugin/keyscribe.json").path))
    }

    @Test func cancellingTheHostsConsentLeavesItOffAndRunsNothing() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let (model, _) = pluginModel(calls)
        let (connector, setup) = try pluginSetup(model)
        model.requestInstall(setup, of: connector)
        model.consent = nil
        await model.refresh()
        await model.maintain()
        #expect(!model.isTurnedOn(BBHost.kind))
        #expect(calls.all.isEmpty)
    }

    @Test func aHostWithAPluginIgnoresTheSavedHostList() {
        let (model, _) = pluginModel(BBPluginConnectorTests.Calls())
        model.load(hosts: ["bb"])
        #expect(!model.isTurnedOn(BBHost.kind))
        model.setTurnedOn(BBHost.kind, true)
        #expect(!model.isTurnedOn(BBHost.kind))
    }

    @Test func uninstallingAHostsPluginDisconnectsTheHostHoweverTheUninstallIsReached() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let (model, setup, agents) = installed(calls)
        await setup.install()
        #expect(model.isTurnedOn(BBHost.kind))
        calls.set("plugin remove", status: 1, #"{"ok":false,"error":{"code":"server_unavailable","message":"bb is not running"}}"#)
        await setup.remove()
        #expect(setup.state == .removalUnfinished("bb is not running"))
        #expect(!model.isTurnedOn(BBHost.kind))
        calls.set("plugin remove", #"{"ok":true}"#)
        await setup.remove()
        #expect(!FileManager.default.fileExists(atPath: agents.appendingPathComponent("bb-plugin").path))
        #expect(!model.isTurnedOn(BBHost.kind))
    }

    @Test func uninstallOffersToTurnOffWhatInstallingTurnedOnUntilTheUninstallFinishes() async throws {
        let calls = BBPluginConnectorTests.Calls()
        calls.set("settings show", #"{"experiments":{"threadRowMetadata":true}}"#)
        calls.set("thread-list prefs get", #"{"key":"showRowMetadata","value":false}"#)
        let (_, setup, _) = installed(calls)
        await setup.install()
        #expect(setup.undoesOnUninstall)
        let turnOff = ["thread-list", "prefs", "set", "showRowMetadata", "false", "--json"]
        calls.set("plugin remove", status: 1, #"{"ok":false,"error":{"code":"server_unavailable","message":"bb is not running"}}"#)
        await setup.remove(undoing: true)
        #expect(calls.all.filter { Array($0.0.dropFirst()) == turnOff }.count == 1)
        #expect(setup.undoesOnUninstall)
        calls.set("plugin remove", #"{"ok":true}"#)
        await setup.remove(undoing: true)
        #expect(calls.all.filter { Array($0.0.dropFirst()) == turnOff }.count == 2)
        #expect(!setup.undoesOnUninstall)
    }

    @Test func uninstallingWithoutTheOfferLeavesBbsRowDetailsAsTheyAre() async throws {
        let calls = BBPluginConnectorTests.Calls()
        calls.set("settings show", #"{"experiments":{"threadRowMetadata":false}}"#)
        calls.set("thread-list prefs get", #"{"key":"showRowMetadata","value":false}"#)
        let (_, setup, _) = installed(calls)
        await setup.install()
        await setup.remove()
        #expect(!calls.all.contains { $0.0.contains("false") })
    }

    @Test func aFailedInstallKeepsTheHostConnectedAndOffersUninstall() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let (model, setup, _) = installed(calls)
        calls.set("plugin install", status: 1, #"{"ok":false,"error":{"code":"server_unavailable","message":"bb is not running"}}"#)
        await setup.install()
        #expect(setup.state == .failed("bb is not running"))
        #expect(model.isTurnedOn(BBHost.kind))
        #expect(setup.offersUninstall)
    }

    @Test func aPluginRemovedInsideTheHostReadsAsAReinstallNotANewConsent() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let (model, setup, agents) = installed(calls)
        await setup.install()
        calls.set("plugin list", Self.listed.replacingOccurrences(of: "AGENTS", with: agents.path))
        await setup.refresh()
        #expect(setup.state == .status(.ready))
        #expect(!setup.offersReinstall)
        calls.set("plugin list", #"{"plugins":[]}"#)
        await setup.refresh()
        #expect(setup.state == .status(.notInstalled))
        #expect(model.isTurnedOn(BBHost.kind))
        #expect(setup.offersReinstall)
        #expect(setup.offersUninstall)
    }

    @Test func anUnreadableSetupsFileNeverTurnsAConnectedHostOff() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let (model, setup, agents) = installed(calls)
        var reported: [[String]] = []
        model.onHostsChange = { reported.append($0) }
        await setup.install()
        try Data("not json".utf8).write(to: agents.appendingPathComponent(ConnectorSetupRegistry.fileName))
        model.setups.reload()
        await model.refresh()
        await model.maintain()
        #expect(model.isTurnedOn(BBHost.kind))
        #expect(reported.isEmpty)
    }

    @Test func eachBbBuildIsItsOwnRowNamedAsItIsCalledAndConnectingAnyTurnsBbOn() async throws {
        let calls = BBPluginConnectorTests.Calls()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bbbuilds-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = root.appendingPathComponent("agents", isDirectory: true)
        let usual = BBBuild(folder: ConnectorFolders.canonical(home.appendingPathComponent(".bb")).path, bundle: "dev.bb.desktop", name: "bb")
        let acme = BBBuild(folder: ConnectorFolders.canonical(home.appendingPathComponent(".acme-bb")).path, bundle: "com.example.acme-bb", name: "bb (Acme)")
        let plugin = BBPluginConnector(
            agentsDir: agents, pluginName: "keyscribe-dev", home: home, sources: BBPluginConnectorTests.sources, isExecutable: { _ in true },
            run: { argv, subcommand, _, environment in
                calls.record(argv, environment)
                return calls.answer(subcommand)
            }, find: { [usual, acme] }, isOpen: { $0 == acme })
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: agents, setups: ConnectorSetupRegistry(directory: agents), connectors: [plugin],
            hosts: [BBHost.kind])
        await model.refresh()
        let connector = try #require(model.connectors.first)
        #expect(connector.setups.map(\.folder.path) == [acme.folder, usual.folder])
        #expect(connector.setups.map(\.name) == ["bb (Acme)", "bb"])
        let open = try #require(connector.setups.first { $0.isDefault })
        #expect(open.folder.path == acme.folder)
        await open.install()
        #expect(model.isTurnedOn(BBHost.kind))
        #expect(calls.all.allSatisfy { $0.0[0] == acme.launcher })
    }

    @Test func aHostsListingProblemIsShownBesideItsSwitchOnlyWhileItIsOn() {
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: FileManager.default.temporaryDirectory, connectors: [], hosts: [BBHost.kind])
        model.show([], discoveryProblems: ["bb": "bb isn\u{2019}t open. Open bb to reach its threads."])
        #expect(model.problem(of: BBHost.kind) == nil)
        model.load(hosts: ["bb"])
        #expect(model.problem(of: BBHost.kind) == "bb isn\u{2019}t open. Open bb to reach its threads.")
        model.show([], discoveryProblems: [:])
        #expect(model.problem(of: BBHost.kind) == nil)
    }
}
