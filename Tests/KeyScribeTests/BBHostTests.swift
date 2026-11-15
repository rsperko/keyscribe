import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct BBHostTests {
    final class Runner: @unchecked Sendable {
        var answers: [String: Result<HostCLI.Output, HostCLI.Failure>] = [:]
        var answersOnlyOnceCancelled = false
        private(set) var calls: [(argv: [String], input: String?, environment: [String: String])] = []

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

    private func host(
        _ runner: Runner, installed: Bool = true, running: Bool = true, frontmost: @escaping @MainActor () -> AgentHostApp? = { nil }
    ) -> (BBHost, () -> Int) {
        var activations = 0
        let host = BBHost(
            home: Self.home, installed: { $0 == Self.cli && installed }, running: { running },
            run: { try await runner.run($0, subcommand: $1, input: $2, environment: $3) },
            activate: { activations += 1 }, frontmost: frontmost)
        return (host, { activations })
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
            titles: ["thr_abc1": "ks-probe pi"], shownInstead: ["thr_abc2": "Reply with ready"]))
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
        #expect(call.argv == [Self.cli, "thread", "tell", "thr_abc1", "--message-file", "-", "--mode", "queue", "--json"])
        #expect(call.input == "run the tests; $(rm -rf ~)")
    }

    @Test func clipboardImagesAreAttachedToTheMessage() async {
        let runner = Runner()
        runner.answers["thread tell"] = Self.output(#"{"ok":true,"delivery":"sent"}"#)
        _ = await host(runner).0.deliver("see /tmp/a.png and /tmp/b.png", images: ["/tmp/a.png", "/tmp/b.png"], request: "r1", to: Self.location)
        #expect(runner.calls.first?.argv == [
            Self.cli, "thread", "tell", "thr_abc1", "--message-file", "-", "--mode", "queue", "--json", "--image", "/tmp/a.png", "--image", "/tmp/b.png",
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
        let bb = AgentHostApp(bundle: BBHost.app, pid: 31, name: "bb", window: "cg:4")
        let other = AgentHostApp(bundle: "com.apple.Safari", pid: 32, name: "Safari")
        var front: AgentHostApp? = bb
        let (host, _) = host(Runner(), frontmost: { front })
        let elsewhere = AgentHostLocation(host: "bb", instance: "/Users/a/.bb", native: "thr_other")
        #expect(await host.front(among: [Self.location], reported: Self.location) == .shown(Self.location, in: bb))
        #expect(await host.front(among: [Self.location], reported: nil) == .unknown)
        #expect(await host.front(among: [Self.location], reported: elsewhere) == .unknown)
        front = other
        #expect(await host.front(among: [Self.location], reported: Self.location) == .elsewhere)
        front = nil
        #expect(await host.front(among: [Self.location], reported: Self.location) == .unknown)
        front = AgentHostApp(bundle: BBHost.app, pid: 31, name: "bb")
        #expect(await host.front(among: [Self.location], reported: Self.location) == .unknown)
    }
}

@MainActor
struct AgentHostConsentModelTests {
    @Test func turningAHostOnOrOffReportsTheWholeListOnceAndLoadingReportsNothing() {
        let model = CodingAgentsSettingsModel(
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

    private func pluginModel(_ calls: BBPluginConnectorTests.Calls) -> (CodingAgentsSettingsModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bbconsent-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".bb/bin"), withIntermediateDirectories: true)
        let agents = root.appendingPathComponent("agents", isDirectory: true)
        let plugin = BBPluginConnector(
            agentsDir: agents, pluginName: "keyscribe-dev", home: home, sources: BBPluginConnectorTests.sources, isExecutable: { _ in true },
            run: { argv, subcommand, _, environment in
                calls.record(argv, environment)
                return calls.answer(subcommand)
            })
        let model = CodingAgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: agents, setups: ConnectorSetupRegistry(directory: agents), connectors: [plugin],
            hosts: [BBHost.kind])
        return (model, agents)
    }

    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    private func pluginSetup(_ model: CodingAgentsSettingsModel) throws -> (AgentConnectorModel, ConnectorSetupModel) {
        let connector = try #require(model.connectors.first)
        let setup = try #require(connector.setups.first { $0.isDefault })
        return (connector, setup)
    }

    private func installed(_ calls: BBPluginConnectorTests.Calls) -> (CodingAgentsSettingsModel, ConnectorSetupModel, URL) {
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

    @Test func aHostsListingProblemIsShownBesideItsSwitchOnlyWhileItIsOn() {
        let model = CodingAgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: FileManager.default.temporaryDirectory, connectors: [], hosts: [BBHost.kind])
        model.show([], current: nil, discoveryProblems: ["bb": "bb isn\u{2019}t open. Open bb to reach its threads."])
        #expect(model.problem(of: BBHost.kind) == nil)
        model.load(hosts: ["bb"])
        #expect(model.problem(of: BBHost.kind) == "bb isn\u{2019}t open. Open bb to reach its threads.")
        model.show([], current: nil, discoveryProblems: [:])
        #expect(model.problem(of: BBHost.kind) == nil)
    }
}
