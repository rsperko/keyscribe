import Foundation
@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentsSettingsModelTests {
    final class CLI: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var heldWord: String?
        private var waiting = false
        var installed: String?
        var failing: Set<String> = []
        var marketplace = false
        var calls: [[String]] { lock.withLock { _calls } }

        func holdNext(_ word: String) { lock.withLock { heldWord = word } }
        func release() { lock.withLock { waiting = false } }

        func run(_ argv: [String]) -> (Int32, String) {
            let held = lock.withLock {
                _calls.append(argv)
                guard let word = heldWord, argv.contains(word) else { return false }
                heldWord = nil
                waiting = true
                return true
            }
            let result = respond(argv)
            while held, lock.withLock({ waiting }) { usleep(1000) }
            return result
        }

        private func respond(_ argv: [String]) -> (Int32, String) {
            if let word = failing.first(where: argv.contains) { return (1, "boom: \(word)") }
            if argv.suffix(3) == ["plugin", "list", "--json"] {
                guard let installed else { return (0, "[]") }
                return (0, #"[{"id":"keyscribe-dev@keyscribe-dev-local","version":"\#(installed)","enabled":true,"scope":"user"}]"#)
            }
            if argv.suffix(3) == ["marketplace", "list", "--json"] { return (0, marketplace ? #"[{"name":"keyscribe-dev-local"}]"# : "[]") }
            if argv.contains("add") { marketplace = true }
            if argv.contains("install") || argv.contains("update") { installed = ClaudeConnectorFiles.registerJS.map { ClaudeConnectorFiles.version(for: $0, surfaces: .builtIn) } }
            if argv.contains("uninstall") { installed = nil }
            if argv.contains("remove") {
                marketplace = false
                installed = nil
            }
            return (0, "")
        }
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func makeModel(
        claude: String? = "/bin/claude-test", cli: CLI = CLI(), terminals: Terminals = Terminals(),
        script: String? = ClaudeConnectorFiles.registerJS, dir: URL? = nil
    ) -> (AgentsSettingsModel, CLI, URL) {
        let dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("ks-agents-model-\(UUID().uuidString)")
        let tools = ToolEnvironment(
            home: dir.appendingPathComponent("home").path, appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh",
            isExecutable: { (claude != nil && $0 == "/test-bin/claude") || ($0.hasPrefix(dir.path) && FileManager.default.isExecutableFile(atPath: $0)) })
        let connector = ClaudeConnector(
            run: { argv, _ in cli.run(argv) }, version: { _ in .working("2.1.326") }, tools: tools, agentsDir: dir, pluginName: "keyscribe-dev", surfaces: .builtIn, script: script,
            home: dir.appendingPathComponent("home"))
        let model = AgentsSettingsModel(describeTerminal: terminals.describe, agentsDir: dir, connectors: [connector])
        return (model, cli, dir)
    }

    private func setup(_ model: AgentsSettingsModel) -> ConnectorSetupModel { model.connectors[0].setups[0] }

    private func defaultFolder(_ dir: URL) -> String {
        ConnectorFolders.canonical(dir.appendingPathComponent("home/.claude")).path
    }

    @Test func aMissingConnectorIsUnavailableAndNeverRunsClaudeCode() async {
        let (model, cli, dir) = makeModel(script: nil)
        await model.refresh()
        #expect(setup(model).state == .unavailable)
        await setup(model).install()
        #expect(setup(model).state == .unavailable)
        #expect(cli.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("claude-connector").path))
    }

    @Test func aRegistrationThisSetupNeverInstalledIsNotItsConnector() async {
        let cli = CLI()
        cli.installed = ClaudeConnectorFiles.registerJS.map { ClaudeConnectorFiles.version(for: $0, surfaces: .builtIn) }
        let (model, _, _) = makeModel(cli: cli)
        await model.refresh()
        #expect(setup(model).state == .status(.notInstalled))
        await setup(model).install()
        #expect(setup(model).state == .status(.ready))
    }

    @Test func aCommandChosenByHandIsUsedAndKeptWithTheFoldersEnrollment() async throws {
        let cli = CLI()
        cli.installed = ClaudeConnectorFiles.registerJS.map { ClaudeConnectorFiles.version(for: $0, surfaces: .builtIn) }
        let (model, _, dir) = makeModel(claude: nil, cli: cli)
        await model.refresh()
        #expect(setup(model).state == .toolNotFound)
        #expect(setup(model).toolMissing)
        let chosen = dir.appendingPathComponent("my-claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: chosen)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path)
        #expect(await setup(model).choose(tool: dir.appendingPathComponent("not-there")) != nil)
        #expect(await setup(model).choose(tool: chosen) == nil)
        #expect(setup(model).search?.tool == ToolSearch.Place(path: chosen.path, source: .chosen))
        #expect(setup(model).state == .status(.notInstalled))
        await setup(model).install()
        #expect(setup(model).state == .status(.ready))
        #expect(model.setups.setups?.setup(agent: "claude", folder: defaultFolder(dir))?.tool == chosen.path)
        #expect(cli.calls.allSatisfy { $0.first == chosen.path })
        #expect(await setup(model).choose(tool: nil) == nil)
        #expect(model.setups.setups?.setup(agent: "claude", folder: defaultFolder(dir))?.tool == nil)
        #expect(setup(model).state == .toolNotFound)
    }

    @Test func aChosenCommandThatFailsOffersOnlyChoosingAgain() async throws {
        let (model, _, dir) = makeModel(claude: nil)
        await model.refresh()
        #expect(setup(model).lookedIn?.isEmpty == false)
        let folder = URL(fileURLWithPath: defaultFolder(dir), isDirectory: true)
        let marketplace = ClaudeConnectorInstaller.marketplaceDir(in: dir, setupFolder: folder)
        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        await model.refresh()
        #expect(setup(model).canUninstallWithoutTool)
        let chosen = dir.appendingPathComponent("broken-claude")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: chosen)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path)
        let failing = ClaudeConnector(
            run: { _, _ in (0, "[]") }, version: { _ in .exited(1, "") },
            tools: ToolEnvironment(home: dir.path, appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh", isExecutable: { $0 == chosen.path }),
            agentsDir: dir, pluginName: "keyscribe-dev", surfaces: .builtIn, home: dir.appendingPathComponent("home"))
        let broken = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: dir, connectors: [failing])
        await broken.refresh()
        #expect(await broken.connectors[0].setups[0].choose(tool: chosen) == nil)
        #expect(broken.connectors[0].setups[0].state == .toolNotWorking(.exited(1, "")))
        #expect(broken.connectors[0].setups[0].lookedIn == nil)
        #expect(broken.connectors[0].setups[0].manualUninstall.isEmpty)
        #expect(!broken.connectors[0].setups[0].offersUninstall)
    }

    @Test func aConversationStillConnectedToASetupThatIsNotInstalledIsWarnedAbout() async {
        let (model, _, dir) = makeModel()
        model.show([conversation("backend", pid: 1, setup: defaultFolder(dir))])
        #expect(setup(model).showsRemovalWarning)
        model.show([])
        #expect(!setup(model).showsRemovalWarning)
        await setup(model).install()
        model.show([conversation("backend", pid: 1, setup: defaultFolder(dir))])
        #expect(!setup(model).showsRemovalWarning)
        #expect(setup(model).usedBy == ["backend"])
    }

    @Test func withoutClaudeCodeNothingRunsAndItSaysSo() async {
        let (model, cli, _) = makeModel(claude: nil)
        await model.refresh()
        await setup(model).install()
        #expect(setup(model).state == .toolNotFound)
        #expect(cli.calls.isEmpty)
    }

    @Test func installEnrollsTheSetupThenAddsTheMarketplaceAndPluginAndChecksAgain() async {
        let (model, cli, dir) = makeModel()
        await model.refresh()
        #expect(setup(model).state == .status(.notInstalled))
        #expect(!setup(model).isEnrolled)

        await setup(model).install()
        let market = ClaudeConnectorInstaller.marketplaceDir(in: dir, setupFolder: URL(fileURLWithPath: defaultFolder(dir)))
        #expect(cli.calls.map { Array($0.dropFirst()) }.contains(["plugin", "marketplace", "add", market.path]))
        #expect(cli.calls.map { Array($0.dropFirst()) }.contains(["plugin", "install", "keyscribe-dev@keyscribe-dev-local", "--scope", "user"]))
        #expect(setup(model).state == .status(.ready))
        #expect(setup(model).isEnrolled)
    }

    @Test func theReloadHintShowsOnlyWhileAConversationIsUnconnectedOrOnThePreviousConnector() async {
        let (model, _, dir) = makeModel()
        await setup(model).install()
        #expect(!setup(model).needsReload)
        var row = conversation("backend", pid: 1, setup: defaultFolder(dir))
        row.connectorLive = false
        model.show([row])
        #expect(setup(model).needsReload)
        row.connectorLive = true
        model.show([row], olderConnectors: ["backend"])
        #expect(setup(model).needsReload)
        model.show([row], olderConnectors: [])
        #expect(!setup(model).needsReload)
    }

    @Test func aFailedInstallShowsWhatClaudeSaid() async {
        let cli = CLI()
        cli.failing = ["install"]
        let (model, _, _) = makeModel(cli: cli)
        await setup(model).install()
        #expect(setup(model).state == .failed("boom: install"))
        #expect(!setup(model).needsReload)
    }

    @Test func connectorFailuresNeedAttentionButAnUninstalledConnectorDoesNot() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await model.refresh()
        #expect(!model.hasError)
        cli.failing = ["install"]
        await setup(model).install()
        #expect(model.hasError)
        #expect(setup(model).hasError)
        cli.failing = []
        await setup(model).retry()
        #expect(!model.hasError)
    }

    @Test func unreadableNamesAndUnsavedDisconnectionsNeedAttentionUntilRecovered() {
        let (model, _, _) = makeModel()
        model.show([], namesProblem: "unreadable")
        #expect(model.hasError)
        model.show([], exclusionsNotSaved: "read only")
        #expect(model.hasError)
        model.show([])
        #expect(!model.hasError)
    }

    @Test func onlyOtherwiseIdenticalProcessRowsGetStartTimeContextWithoutChangingTheirNames() throws {
        let (model, _, _) = makeModel()
        let first = AgentCandidate(agent: "claude", pid: 7, startedAt: 5_000, cwd: "/src/atlas", setup: "/x/.claude")
        let second = AgentCandidate(agent: "claude", pid: 8, startedAt: 65_000, cwd: "/src/atlas", setup: "/x/.claude")
        model.show([], discoveredSetups: ["claude": ["/x/.claude"]], candidates: [first, second])
        #expect(model.rows.map(\.name) == ["Claude Code in atlas", "Claude Code in atlas"])
        let contexts = try model.rows.map { try #require(model.recognitionContext(for: $0)) }
        #expect(Set(contexts).count == 2)
        #expect(contexts.allSatisfy { $0.hasPrefix("Started ") })
        model.connect(model.rows[0])
        let request = try #require(model.consent)
        #expect(Set(model.affected(by: request)).count == 2)
        model.show([], candidates: [first])
        #expect(model.recognitionContext(for: model.rows[0]) == nil)
    }

    @Test func aRevealedProcessRowIsTheOneTheHUDNamed() {
        let (model, _, _) = makeModel()
        let candidate = AgentCandidate(agent: "claude", pid: 7, startedAt: 5_000, cwd: "/src/atlas", setup: "/x/.claude")
        model.show([], candidates: [candidate])
        #expect(model.rows.map(\.id) == [candidate.rowId])
        model.reveal([candidate.rowId])
        #expect(model.pendingReveal == [candidate.rowId])
        model.reveal([])
        #expect(model.pendingReveal.isEmpty)
    }

    @Test func aRevealWhoseRowNeverAppearsLapses() {
        let (model, _, _) = makeModel()
        var now = Date(timeIntervalSince1970: 1_000)
        model.now = { now }
        model.reveal(["claude:7"])
        now += AgentsSettingsModel.revealLasts - 1
        #expect(model.pendingReveal == ["claude:7"])
        now += 1
        #expect(model.pendingReveal.isEmpty)
    }

    @Test func removeUninstallsAndForgetsTheReloadHint() async {
        let (model, _, _) = makeModel()
        await setup(model).install()
        await setup(model).remove()
        #expect(setup(model).state == .status(.notInstalled))
        #expect(!setup(model).needsReload)
        #expect(model.setups.setups?.setups.isEmpty == true)
    }

    @Test func removeRevokesTheInstallationAndRetiresItsConnectorsBeforeAnyUninstallCommand() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await setup(model).install()
        let installation = setup(model).target.installation
        #expect(model.setups.admits(agent: "claude", installation: installation))
        var atRetire: (admitted: Bool, retired: String, uninstalls: Int)?
        model.onRetire = { [setups = model.setups] retired in
            atRetire = (setups.admits(agent: "claude", installation: installation), retired, cli.calls.filter { $0.contains("uninstall") }.count)
        }
        await setup(model).remove()
        #expect(atRetire?.admitted == false)
        #expect(atRetire?.retired == installation)
        #expect(atRetire?.uninstalls == 0)
        #expect(cli.calls.contains { $0.contains("uninstall") })
    }

    @Test func aConnectorStillInClaudeCodeAfterAFailedRemovalIsShownAsUnfinishedUntilRemovedAgain() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await setup(model).install()
        let installation = setup(model).target.installation
        cli.failing = ["uninstall", "remove"]
        await setup(model).remove()
        #expect(setup(model).state == .removalUnfinished("boom: uninstall"))
        #expect(!model.setups.admits(agent: "claude", installation: installation))

        cli.failing = []
        await setup(model).remove()
        #expect(setup(model).state == .status(.notInstalled))
        #expect(!model.setups.admits(agent: "claude", installation: installation))
    }

    @Test func anUninstallThatLeavesOnlyTheMarketplaceBehindStaysUnfinishedUntilRetried() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await setup(model).install()
        cli.failing = ["remove"]
        await setup(model).remove()
        #expect(cli.installed == nil && cli.marketplace)
        #expect(setup(model).state == .removalUnfinished("boom: remove"))
        await model.refresh()
        #expect(setup(model).state == .removalUnfinished(nil))

        cli.failing = []
        await setup(model).remove()
        #expect(setup(model).state == .status(.notInstalled))
    }

    @Test func withoutClaudeCodeAnInstalledConnectorCanStillBeUninstalledAndOffersTheCommandsToFinish() async {
        let cli = CLI()
        let (installed, _, dir) = makeModel(cli: cli)
        let (model, _, _) = makeModel(claude: nil, cli: cli, dir: dir)
        await model.refresh()
        #expect(setup(model).manualUninstall.isEmpty)
        #expect(!setup(model).canUninstallWithoutTool)
        #expect(setup(model).manualUninstallLead == nil)
        #expect(setup(model).uninstallWithoutToolNote == nil)

        await setup(installed).install()
        model.setups.reload()
        await model.refresh()
        #expect(setup(model).canUninstallWithoutTool)
        #expect(setup(model).uninstallWithoutToolNote == "Claude Code wasn\u{2019}t found. Choose Uninstall to remove the connector here and get the commands that finish it in a terminal.")
        #expect(setup(model).manualUninstall.isEmpty)
        #expect(setup(model).manualUninstallLead == nil)

        await setup(model).remove()
        #expect(!setup(model).canUninstallWithoutTool)
        #expect(setup(model).uninstallWithoutToolNote == nil)
        #expect(setup(model).manualUninstall == [
            "env -u CLAUDE_CONFIG_DIR claude plugin uninstall keyscribe-dev@keyscribe-dev-local --scope user",
            "env -u CLAUDE_CONFIG_DIR claude plugin marketplace remove keyscribe-dev-local",
        ])
        #expect(setup(model).manualUninstallLead == "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling, then run /reload-plugins in each open conversation or restart it:")
    }

    @Test func removeStillRevokesTheSetupWhenClaudeCannotBeFound() async {
        let cli = CLI()
        let (installed, _, dir) = makeModel(cli: cli)
        await setup(installed).install()
        let installation = setup(installed).target.installation
        let (model, _, _) = makeModel(claude: nil, cli: cli, dir: dir)
        var retired: String?
        model.onRetire = { retired = $0 }
        await setup(model).remove()
        #expect(retired == installation)
        #expect(!model.setups.admits(agent: "claude", installation: installation))
        #expect(setup(model).state == .toolNotFound)
    }

    @Test func aRefreshDuringAnInstallLeavesItInProgressAndASecondInstallDoesNothing() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await model.refresh()
        cli.holdNext("install")
        let installing = Task { await setup(model).install() }
        await until { cli.calls.contains { $0.contains("install") } }
        #expect(setup(model).operation == "Installing\u{2026}")

        await model.refresh()
        await setup(model).install()
        await setup(model).remove()
        #expect(setup(model).operation == "Installing\u{2026}")
        #expect(cli.calls.filter { $0.contains("install") || $0.contains("uninstall") }.count == 1)

        cli.release()
        await installing.value
        #expect(setup(model).operation == nil)
        #expect(setup(model).state == .status(.ready))
    }

    @Test func aRefreshThatStartedBeforeAnInstallCannotUndoIt() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        cli.holdNext("list")
        let refreshing = Task { await model.refresh() }
        await until { !cli.calls.isEmpty }

        await setup(model).install()
        #expect(setup(model).state == .status(.ready))
        cli.release()
        await refreshing.value
        #expect(setup(model).state == .status(.ready))
    }

    @Test func eachSetupAConversationUsesIsListedWithoutBeingEnrolled() {
        let (model, _, dir) = makeModel()
        model.show([conversation("backend", pid: 1, setup: "/work/.claude")], discoveredSetups: ["claude": ["/work/.claude"]])
        #expect(model.connectors[0].setups.map(\.folder.path) == [defaultFolder(dir), "/work/.claude"])
        #expect(model.connectors[0].setups[1].usedBy == ["backend"])
        #expect(model.setups.setups?.setups.isEmpty == true)
    }

    @Test func aConversationWhoseSetupHasNoConnectorOffersConnectAndOneWithItsConnectorOffersRecovery() async {
        let (model, _, dir) = makeModel()
        var row = conversation("backend", pid: 1, setup: defaultFolder(dir))
        row.connectorLive = false
        model.show([row])
        #expect(model.action(for: model.rows[0]) == .connect)
        #expect(model.awaitingReload(of: model.connectors[0]).isEmpty)
        model.connect(model.rows[0])
        let request = try? #require(model.consent)
        #expect(request?.setup === setup(model))
        #expect(request.map(model.affected(by:)) == ["backend"])
        if let request { model.confirm(request) }
        #expect(model.consent == nil)
        await until { setup(model).state == .status(.ready) }
        #expect(model.action(for: model.rows[0]) == .recover(.claude))
        #expect(model.awaitingReload(of: model.connectors[0]).map(\.name) == ["backend"])
        row.connectorLive = true
        model.show([row])
        #expect(model.action(for: model.rows[0]) == .connected)
        #expect(model.awaitingReload(of: model.connectors[0]).isEmpty)
    }

    @Test func aProcessFoundBeforeItsConnectorSaysHelloIsListedButCannotBeRenamedOrAddressed() {
        let (model, _, _) = makeModel()
        model.show([], candidates: [
            AgentCandidate(agent: "claude", pid: 7, startedAt: 5_000, cwd: "/src/atlas", setup: "/x/.claude"),
        ])
        #expect(model.rows.count == 1)
        #expect(model.rows[0].name == "Claude Code in atlas")
        #expect(!model.rows[0].identified)
        #expect(model.rows[0].state == "Not connected")
        #expect(model.rows[0].key == "7:5000")
        model.show([AgentConversation(
            id: "claude:abc", agent: "claude", pid: 7, cwd: "/src/atlas", handle: "atlas", state: .idle, connectorLive: true,
            startedAt: Date(timeIntervalSince1970: 5), setup: "/x/.claude")])
        #expect(model.rows.map(\.key) == ["7:5000"])
        #expect(model.rows[0].identified)
    }

    @Test func disconnectingAndReconnectingGoThroughTheHubAndReconnectingAnUninstalledSetupAsksFirst() {
        let (model, _, dir) = makeModel()
        var asked: [String] = []
        model.onDisconnect = { asked.append("disconnect \($0)") }
        model.onReconnect = { asked.append("reconnect \($0)") }
        model.show([conversation("backend", pid: 1, setup: defaultFolder(dir))])
        model.disconnect(model.rows[0])
        var away = conversation("backend", pid: 1, setup: defaultFolder(dir))
        away.connectorLive = false
        model.show([], disconnected: [away])
        #expect(model.disconnectedRows.map(\.name) == ["backend"])
        model.reconnect(model.disconnectedRows[0])
        #expect(asked == ["disconnect backend"])
        #expect(model.consent?.setup === setup(model))
    }

    @Test func aConversationWhoseReplyWillBeReadAloudSaysSoAndCanCancelIt() {
        let (model, _, dir) = makeModel()
        var cancelled: [String] = []
        model.onCancelReadAloud = { cancelled.append($0) }
        model.show(
            [conversation("backend", pid: 1, setup: defaultFolder(dir)), conversation("docs", pid: 2, setup: defaultFolder(dir)),
             conversation("web", pid: 3, setup: defaultFolder(dir))],
            readAloud: ["backend"], readNextAloud: ["web"])
        #expect(model.rows.map(\.readAloud?.note) == ["Reply will be reported.", nil, "Next reply will be reported."])
        model.cancelReadAloud(model.rows[0])
        #expect(cancelled == ["backend"])
    }

    @Test func reconnectingThroughAnInstallReconnectsOnceTheInstallSucceeds() async throws {
        let (model, _, dir) = makeModel()
        var reconnected: [String] = []
        model.onReconnect = { reconnected.append($0) }
        var away = conversation("backend", pid: 1, setup: defaultFolder(dir))
        away.connectorLive = false
        var other = conversation("api", pid: 2, setup: defaultFolder(dir))
        other.connectorLive = false
        model.show([], disconnected: [away, other])
        model.reconnect(model.disconnectedRows[0])
        let request = try #require(model.consent)
        #expect(model.affected(by: request) == ["backend"])
        #expect(model.stayingDisconnected(by: request) == ["api"])
        model.confirm(request)
        await until { !reconnected.isEmpty }
        #expect(reconnected == ["backend"])
    }

    @Test func aFailedInstallIsNotTreatedAsInstalledAndTryAgainInstallsAgain() async {
        let cli = CLI()
        cli.failing = ["install"]
        let (model, _, dir) = makeModel(cli: cli)
        var row = conversation("backend", pid: 1, setup: defaultFolder(dir))
        row.connectorLive = false
        model.show([row])
        await setup(model).install()
        guard case .failed = setup(model).state else { Issue.record("not failed: \(setup(model).state)"); return }
        #expect(setup(model).isEnrolled)
        #expect(model.action(for: model.rows[0]) == .connect)
        cli.failing = []
        await setup(model).retry()
        #expect(setup(model).state == .status(.ready))
        #expect(!cli.calls.contains { $0.contains("update") })
    }

    @Test func aRepairedConnectorsFileIsReadAgainFromSettings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agents-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(ConnectorSetupRegistry.fileName)
        try Data("not json".utf8).write(to: file)
        let (model, _, _) = makeModel(dir: dir)
        #expect(model.setupsProblem != nil)
        #expect(model.hasError)
        try FileManager.default.removeItem(at: file)
        await model.retrySetups()
        #expect(model.setupsProblem == nil)
        #expect(!model.hasError)
        await setup(model).install()
        #expect(setup(model).state == .status(.ready))
    }

    @Test func whileNamesCannotBeReadNoConversationIsOfferedForReconnectAndTheListSaysWhy() {
        let (model, _, _) = makeModel()
        var away = conversation("backend", pid: 1)
        away.connectorLive = false
        model.show([], namesProblem: "unreadable", disconnected: [away])
        #expect(model.disconnectedRows.isEmpty)
        #expect(model.emptyState == "Conversations stay disconnected until \(AgentNameStore.fileName) can be read.")
    }

    @Test func onlyConversationsCarriedFromAnEarlierScanAreLastSeen() {
        let (model, _, _) = makeModel()
        var fresh = conversation("backend", pid: 1)
        fresh.connectorLive = false
        var carried = conversation("api", pid: 2)
        carried.connectorLive = false
        model.show([fresh, carried], discoveryProblems: ["claude": "partial"], lastSeen: ["api"])
        #expect(model.rows.first { $0.name == "api" }?.state == "Last seen")
        #expect(model.rows.first { $0.name == "backend" }?.lastSeen == false)
    }

    @Test func aHostedConversationLastSeenInACopyThatCannotBeReachedIsLastSeenAndNotCountedAvailable() {
        let (model, _, _) = makeModel()
        var listed = conversation("docs", pid: 1)
        listed.connectorLive = false
        listed.host = AgentHostLocation(host: "bb", instance: "/Users/me/.bb", native: "thr_a")
        var carried = conversation("api", pid: 2)
        carried.connectorLive = false
        carried.host = AgentHostLocation(host: "bb", instance: "/Users/me/.bb-work", native: "thr_b")
        model.show([listed, carried], lastSeen: ["api"])
        #expect(model.rows.first { $0.name == "api" }?.state == "Last seen")
        #expect(model.rows.first { $0.name == "api" }?.connected == false)
        #expect(model.rows.first { $0.name == "docs" }?.connected == true)
        #expect(model.conversationsSummary == "1 available")
    }

    @Test func aSetupFoundAfterThePaneOpenedIsCheckedWithoutReopeningIt() async {
        let (model, _, _) = makeModel()
        await model.refresh()
        model.show([], discoveredSetups: ["claude": ["/work/.claude"]])
        let late = model.connectors[0].setups.first { $0.folder.path == "/work/.claude" }
        await until { late?.state != .checking }
        #expect(late?.state == .status(.notInstalled))
    }

    @Test func describingTerminalsKeepsTheNoteAboutAnOlderConnector() async {
        let terminals = Terminals()
        terminals.byPid[1] = "Ghostty"
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("backend", pid: 1)], olderConnectors: ["backend"])
        await until { model.rows.first?.terminal == "Ghostty" }
        #expect(model.rows.first?.olderConnector == true)
    }

    @Test func aConversationStillRunningThePreviousConnectorIsNotedAndOneOnTheCurrentIsNot() {
        let (model, _, _) = makeModel()
        model.show([conversation("backend", pid: 1), conversation("api", pid: 2)], olderConnectors: ["backend"])
        #expect(model.rows.first { $0.name == "backend" }?.olderConnector == true)
        #expect(model.rows.first { $0.name == "api" }?.olderConnector == false)
    }

    @Test func aDisconnectThatCouldNotBeSavedIsShown() {
        let (model, _, _) = makeModel()
        model.show([], exclusionsNotSaved: "disk full")
        #expect(model.exclusionsNotSaved == "disk full")
    }

    @Test func choosingAFolderThatIsNotASetupSaysSoAndARealOneAsksBeforeInstalling() throws {
        let (model, _, dir) = makeModel()
        let empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(model.choose(folder: empty, for: model.connectors[0])?.contains("doesn\u{2019}t look like") == true)
        #expect(model.consent == nil)
        let real = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("projects"), withIntermediateDirectories: true)
        #expect(model.choose(folder: real, for: model.connectors[0]) == nil)
        #expect(model.consent?.setup.folder.path == ConnectorFolders.canonical(real).path)
        #expect(model.setups.setups?.setups.isEmpty == true)
    }

    @Test func addingAFolderAlreadyListedUnderAnotherPathSaysSoAndAddsNothing() throws {
        let (model, _, dir) = makeModel()
        let connector = model.connectors[0]
        let real = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("work-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(model.choose(folder: real, for: connector) == nil)
        model.consent = nil
        let before = connector.setups.map(\.folder.path)
        #expect(model.choose(folder: link, for: connector)?.hasSuffix("is already listed.") == true)
        #expect(model.choose(folder: URL(fileURLWithPath: real.path + "/"), for: connector)?.hasSuffix("is already listed.") == true)
        #expect(model.choose(folder: connector.connector.defaultFolder, for: connector)?.hasSuffix("is already listed.") == true)
        #expect(connector.setups.map(\.folder.path) == before)
        #expect(model.consent == nil)
    }

    @Test func aFolderAddedButNeverInstalledCanBeRemovedFromTheListAndTheDefaultCannot() throws {
        let (model, _, dir) = makeModel()
        let connector = model.connectors[0]
        let real = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("projects"), withIntermediateDirectories: true)
        _ = model.choose(folder: real, for: connector)
        let added = try #require(connector.setup(for: ConnectorFolders.canonical(real).path))
        let defaults = connector.setups.filter { $0.isDefault }
        let fallback = try #require(defaults.first)
        #expect(connector.canForget(added))
        #expect(!connector.canForget(fallback))
        connector.forget(added)
        #expect(connector.setup(for: ConnectorFolders.canonical(real).path) == nil)
        #expect(FileManager.default.fileExists(atPath: real.path))
    }

    @Test func conversationsSayWhetherTheyCanReceiveBeforeWhatTheyAreDoing() {
        let (model, _, _) = makeModel()
        model.show([
            AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/keyscribe", handle: "keyscribe", state: .working, connectorLive: true),
            AgentConversation(id: "b", agent: "claude", pid: 2, cwd: "/src/chatplay", handle: "chatplay", state: .idle, connectorLive: false),
            AgentConversation(id: "c", agent: "claude", pid: 3, cwd: "/src/home", handle: "home", state: .idle, connectorLive: true),
        ])
        #expect(model.rows == [
            .init(id: "a", name: "keyscribe", folder: "/src/keyscribe", state: "Working", connected: true, agent: "claude", key: "1:0"),
            .init(id: "b", name: "chatplay", folder: "/src/chatplay", state: "Not connected", connected: false, agent: "claude", key: "2:0"),
            .init(id: "c", name: "home", folder: "/src/home", state: "Ready", connected: true, agent: "claude", key: "3:0"),
        ])
        #expect(model.connectedCount == 2)
    }

    final class Terminals: @unchecked Sendable {
        private let lock = NSLock()
        var byPid: [Int: String] = [:]
        private var _asked: [Int] = []
        var asked: [Int] { lock.withLock { _asked } }
        var describe: @Sendable (Int) -> String? {
            { [self] pid in lock.withLock { _asked.append(pid); return byPid[pid] } }
        }
    }

    @Test func aLateTerminalDescriptionKeepsTheDiscoveryWarning() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("backend", pid: 1)], discoveryProblems: ["claude": "unreadable"])
        #expect(model.connectors[0].discoveryProblem == "unreadable")
        await until { model.rows.first?.terminal == "Ghostty" }
        #expect(model.rows.first?.terminal == "Ghostty")
        #expect(model.connectors[0].discoveryProblem == "unreadable")
        model.show([conversation("backend", pid: 1)], discoveryProblems: [:])
        #expect(model.connectors[0].discoveryProblem == nil)
    }

    private func conversation(_ id: String, pid: Int, title: String? = nil, setup: String? = nil) -> AgentConversation {
        AgentConversation(id: id, agent: "claude", pid: pid, cwd: "/src/\(id)", handle: id, state: .idle, connectorLive: true, title: title, setup: setup)
    }

    @Test func anOpenDialogsRowIsLabelledByItsPromptsKind() {
        let (model, _, _) = makeModel()
        var dialog = conversation("backend", pid: 1)
        dialog.state = .userDialog
        model.show([dialog], prompts: ["backend": AgentPrompt(kind: "confirm")])
        #expect(model.rows.first?.state == "Waiting for approval")
        model.show([dialog])
        #expect(model.rows.first?.state == "Dialog open")
    }

    @Test func renameContextKeepsTheTitleWithItsConversationAsItChanges() {
        let (model, _, _) = makeModel()
        model.show([conversation("backend", pid: 1, title: "Fix the cache")])
        #expect(model.rows.first?.title == "Fix the cache")
        model.show([conversation("backend", pid: 1, title: "Verify the cache")])
        #expect(model.rows.first?.title == "Verify the cache")
        model.show([conversation("backend", pid: 1)])
        #expect(model.rows.first?.title == nil)
    }

    @Test func everyRowNamesItsTerminalIncludingSessionsThatShareOne() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty \u{00B7} herdr", 2: "Ghostty \u{00B7} herdr"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("a", pid: 1), conversation("b", pid: 2)])
        await until { model.rows.allSatisfy { $0.terminal != nil } }
        #expect(model.rows.map(\.terminal) == ["Ghostty \u{00B7} herdr", "Ghostty \u{00B7} herdr"])

        terminals.byPid[3] = "cmux"
        model.show([conversation("a", pid: 1), conversation("b", pid: 2), conversation("c", pid: 3)])
        await until { model.rows.last?.terminal != nil }
        #expect(model.rows.map(\.terminal) == ["Ghostty \u{00B7} herdr", "Ghostty \u{00B7} herdr", "cmux"])
        #expect(terminals.asked.sorted() == [1, 2, 3])
    }

    @Test func differentTerminalsStayWithTheirOwnConversation() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty", 2: "Terminal"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("a", pid: 1), conversation("b", pid: 2)])
        await until { model.rows.allSatisfy { $0.terminal != nil } }
        #expect(model.rows.map(\.terminal) == ["Ghostty", "Terminal"])
    }

    @Test func aProcessIdReusedByALaterConversationIsDescribedAgain() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("a", pid: 1)])
        await until { model.rows.first?.terminal != nil }
        model.show([])
        terminals.byPid[1] = "Terminal"
        model.show([conversation("b", pid: 1)])
        await until { model.rows.first?.terminal == "Terminal" }
        #expect(model.rows.map(\.terminal) == ["Terminal"])
    }

    @Test func directoriesKeepTheirFullPathsEvenForProjectsWithTheSameName() {
        let (model, _, _) = makeModel()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        model.show([
            AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/rsperko/keyscribe", handle: "a", state: .idle, connectorLive: true),
            AgentConversation(id: "b", agent: "claude", pid: 2, cwd: "/src/other/keyscribe", handle: "b", state: .idle, connectorLive: true),
            AgentConversation(id: "c", agent: "claude", pid: 3, cwd: "/src/chatplay", handle: "c", state: .idle, connectorLive: true),
            AgentConversation(id: "d", agent: "claude", pid: 4, cwd: home, handle: "d", state: .idle, connectorLive: true),
        ])
        #expect(model.rows.map(\.folder) == ["/src/rsperko/keyscribe", "/src/other/keyscribe", "/src/chatplay", home])
    }

    @Test func theRenamePreviewAsksTheSameCheckTheRenameUses() {
        let (model, _, _) = makeModel()
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true),
        ])
        var asked: [String] = []
        model.renameCheck = { id, name in
            asked.append("\(id) \(name)")
            return name == "held" ? .taken : nil
        }
        #expect(model.renameIssue("a", name: "held") != nil)
        #expect(model.renameIssue("a", name: "free") == nil)
        #expect(asked == ["a held", "a free"])
    }

    @Test func renamingReportsWhetherTheEditorCanCloseAndKeepsFailuresEditable() {
        let (model, _, _) = makeModel()
        model.onRename = { _, _ in throw AgentHandles.RenameError.taken }
        #expect(!model.rename("a", to: "backend"))
        #expect(model.renameProblem != nil)
        model.clearRenameProblem()
        #expect(model.renameProblem == nil)
        model.onRename = { _, _ in }
        #expect(model.rename("a", to: "backend"))
    }

    @Test func renameValidationUsesTheSpokenNameAndAllowsKeepingYourOwnName() {
        let (model, _, _) = makeModel()
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true),
            .init(id: "b", agent: "claude", pid: 2, cwd: "/src/web", handle: "frontend", state: .idle, connectorLive: true),
        ])
        #expect(model.renameIssue("a", name: "Back End") == nil)
        #expect(model.renameIssue("b", name: "Back End") != nil)
        #expect(model.renameIssue("a", name: "session two") != nil)
        #expect(model.renameIssue("a", name: "  !!! ") != nil)
    }

    @Test func theRenameExampleOffersAShorterNameOnlyWhenItReachesThisConversation() throws {
        let (model, _, _) = makeModel()
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true),
            .init(id: "b", agent: "claude", pid: 2, cwd: "/src/web", handle: "fix authentication tests", state: .idle, connectorLive: true),
        ])
        #expect(model.renameExample("a", name: "Back End") == "Say \u{201C}back end, run the unit tests.\u{201D} \u{201C}tell back, \u{2026}\u{201D} also works.")
        #expect(model.renameExample("a", name: "fix authentication retries")
            == "Say \u{201C}fix authentication retries, run the unit tests.\u{201D}")
        let short = try #require(AgentAddress.shorterSpokenName(for: "deploy the staging cluster", among: ["deploy the staging cluster", "backend", "fix authentication tests"]))
        #expect(model.renameExample("b", name: "deploy the staging cluster")
            == "Say \u{201C}deploy the staging cluster, run the unit tests.\u{201D} \u{201C}tell \(short), \u{2026}\u{201D} also works.")
    }

    @Test func aSaveFailureExplainsTheOutcomeAndKeepsTechnicalDetailsSeparate() {
        let (model, _, _) = makeModel()
        model.onRename = { _, _ in throw NSError(domain: "review", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk unavailable"]) }
        #expect(!model.rename("a", to: "backend"))
        #expect(model.renameProblem == "Could not save this name. Your current name is unchanged.")
        #expect(model.renameDetails == "disk unavailable")
        model.clearRenameProblem()
        #expect(model.renameDetails == nil)
    }

    @Test func aRenameThatWorksClearsTheLastProblem() {
        let (model, _, _) = makeModel()
        var renamed: [String] = []
        model.onRename = { id, name in
            if name == "keyscribe" { throw AgentHandles.RenameError.taken }
            renamed.append("\(id)=\(name)")
        }
        model.rename("b", to: "keyscribe")
        #expect(model.renameProblem == "Another conversation is already called \u{201C}keyscribe\u{201D}. Both names are unchanged.")
        model.rename("b", to: "backend")
        #expect(renamed == ["b=backend"])
        #expect(model.renameProblem == nil)
    }

    @Test func aNamesProblemIsShownAndTryAgainAsksTheHub() {
        let (model, _, _) = makeModel()
        var reloads = 0
        model.onReloadNames = { reloads += 1 }
        model.show([], namesProblem: "names.json could not be read.")
        #expect(model.namesProblem == "names.json could not be read.")
        model.reloadNames()
        #expect(reloads == 1)
        model.show([])
        #expect(model.namesProblem == nil)
        model.show([], namesNotSaved: "names.json could not be written.")
        #expect(model.namesNotSaved == "names.json could not be written.")
        #expect(model.namesProblem == nil)
        model.show([])
        #expect(model.namesNotSaved == nil)
    }

    @Test func aRefusedRenameSaysWhy() {
        let (model, _, _) = makeModel()
        model.onRename = { _, name in
            throw name.trimmingCharacters(in: .whitespaces).isEmpty ? AgentHandles.RenameError.empty : AgentHandles.RenameError.reserved
        }
        model.rename("a", to: "  ")
        #expect(model.renameProblem == "Enter a name.")
        model.rename("a", to: "session 2")
        #expect(model.renameProblem == "\u{201C}Conversation\u{201D} or \u{201C}session\u{201D} followed by a number is how you say a row, so it cannot be a name.")
    }
    @Test func aRowNamesThePlaceItsNameCameFromWithoutRepeatingTheTerminal() async {
        let terminals = Terminals()
        terminals.byPid[1] = "Ghostty \u{00B7} herdr"
        terminals.byPid[2] = "Ghostty"
        let (model, _, _) = makeModel(terminals: terminals)
        let cos = AgentPlaceName(surface: "herdr", level: .workspace, label: "Cos")
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/home", handle: "cos claude", state: .idle, connectorLive: true,
                  nameSource: .place, placeName: cos, placeSurface: "herdr"),
            .init(id: "b", agent: "claude", pid: 2, cwd: "/src/home", handle: "cos pi", state: .idle, connectorLive: true,
                  nameSource: .place, placeName: cos, placeSurface: "herdr"),
            .init(id: "c", agent: "claude", pid: 3, cwd: "/src/api", handle: "api", state: .idle, connectorLive: true, placeSurface: "herdr"),
        ])
        await until { model.rows.filter { $0.id != "c" }.allSatisfy { $0.terminal != nil } }
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        #expect(rows["a"]?.location == "Ghostty \u{00B7} herdr workspace Cos")
        #expect(rows["b"]?.location == "Ghostty \u{00B7} herdr workspace Cos")
        #expect(rows["c"]?.location == nil)
        #expect(rows["c"]?.surface == "herdr")
    }

    @Test func theRenameSheetExplainsWhereTheNameComesFromAndTheDefaultBehindAnOverride() {
        let (model, _, _) = makeModel()
        let row = AgentsSettingsModel.Row(
            id: "a", name: "cos claude", folder: "/src/home", state: "Ready", connected: true, agent: "claude")
        var renamed = row
        renamed.renamed = true
        model.defaultName = { _ in
            AgentDirectory.DefaultName(
                name: "cos claude", source: .place, place: AgentPlaceName(surface: "herdr", level: .workspace, label: "cos"))
        }
        #expect(model.defaultNameNote(row) == "This name comes from its herdr workspace.")
        #expect(model.defaultNameNote(renamed) == "Default name: cos claude, from its herdr workspace.")
        model.defaultName = { _ in AgentDirectory.DefaultName(name: "home", source: .folder, place: nil) }
        #expect(model.defaultNameNote(renamed) == "Default name: home, from its folder.")
    }

    @Test func theRenameSheetListsTheOtherNamesThatReachTheConversation() {
        let (model, _, _) = makeModel()
        var row = AgentsSettingsModel.Row(
            id: "a", name: "marvin", folder: "/src/home", state: "Ready", connected: true, agent: "pi")
        row.otherNames = ["cos", "refactor auth"]
        model.defaultName = { _ in
            AgentDirectory.DefaultName(
                name: "marvin", source: .place, place: AgentPlaceName(surface: "herdr", level: .title, label: "marvin"),
                otherNames: ["cos", "refactor auth"])
        }
        #expect(model.defaultNameNote(row)
            == "This name comes from its herdr pane title. Also answers to \u{201C}cos\u{201D} and \u{201C}refactor auth\u{201D}.")
        #expect(model.alsoAnswers(row) == "Also answers to \u{201C}cos\u{201D} and \u{201C}refactor auth\u{201D}")
    }

    @Test(arguments: [
        (AgentPlace.Level.title, nil as String?, "herdr", "This name is the pane title herdr shows, so it changes when herdr changes it. Rename it here to keep a name of your own."),
        (.title, "title", "bb", "This name is the title bb shows, so it changes when bb changes it. Rename it here to keep a name of your own."),
        (.agent, nil, "herdr", "This name follows this agent. To change it, rename the agent in herdr."),
        (.pane, nil, "herdr", "This name follows this conversation, including when you resume it. To name future conversations in this pane, rename the pane in herdr."),
        (.tab, "window", "tmux", "This name follows this conversation, including when you resume it. To name future conversations in this window, rename the window in tmux."),
    ])
    func theRenameSheetSaysWhatSetsTheNameItCameFrom(level: AgentPlace.Level, term: String?, surface: String, note: String) {
        var row = AgentsSettingsModel.Row(
            id: "a", name: "marvin", folder: "/src/home", state: "Ready", connected: true, agent: "pi")
        row.surface = surface
        row.place = AgentPlaceName(surface: surface, level: level, label: "marvin", term: term)
        #expect(AgentsSettingsModel.placeNote(row) == note)
        row.renamed = true
        #expect(AgentsSettingsModel.placeNote(row) == "This name follows this conversation, including when you resume it.")
        row.renamed = false
        row.place = nil
        #expect(AgentsSettingsModel.placeNote(row)?.hasSuffix("rename the pane in \(surface).") == true)
        row.surface = nil
        #expect(AgentsSettingsModel.placeNote(row) == nil)
    }

    @Test func aConversationWhosePlaceStoppedReadingSaysSoAndKeepsItsNames() {
        var row = AgentsSettingsModel.Row(
            id: "a", name: "marvin", folder: "/src/home", state: "Ready", connected: true, agent: "pi")
        #expect(AgentsSettingsModel.placeTrouble(row) == nil)
        row.surface = "herdr"
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        row.unreadSince = since
        let time = since.formatted(date: .omitted, time: .shortened)
        #expect(AgentsSettingsModel.placeTrouble(row)
            == "Couldn\u{2019}t read its herdr names since \(time). Using the names last read.")
        row.surface = nil
        #expect(AgentsSettingsModel.placeTrouble(row)
            == "Couldn\u{2019}t read where it runs since \(time). Using the names last read.")
    }

    @Test func useDefaultNameReportsAFailedSaveAndKeepsTheSheetOpen() {
        let (model, _, _) = makeModel()
        model.onUseDefaultName = { _ in throw NSError(domain: "review", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk unavailable"]) }
        #expect(!model.useDefaultName("a"))
        #expect(model.renameProblem == "Could not save this change. Your current name is unchanged.")
        #expect(model.renameDetails == "disk unavailable")
        model.onUseDefaultName = { _ in }
        #expect(model.useDefaultName("a"))
        #expect(model.renameProblem == nil)
    }

    final class FolderConnector: AgentConnector {
        let kind = AgentKind(id: "folder", displayName: "Folder Agent", connectorName: "Folder Agent extension")
        let copy = BBPluginConnector(agentsDir: URL(fileURLWithPath: "/tmp"), pluginName: "p").copy
        let isBundled = true
        let bundledVersion: String? = "1"
        let defaultFolder: URL
        var installed = false
        private(set) var toolsSeen: [String] = []

        init(defaultFolder: URL) { self.defaultFolder = defaultFolder }

        func hasFiles(in target: ConnectorTarget) -> Bool { installed }
        func manualUninstall(for target: ConnectorTarget) -> [String] { [] }
        func recognizes(folder: URL) -> Bool { true }
        func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result? { nil }
        func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
            toolsSeen.append(tool)
            if target.removing { return installed ? .removalUnfinished(nil) : .status(.notInstalled) }
            return installed ? .status(.ready) : .status(.notInstalled)
        }
        func install(tool: String, target: ConnectorTarget) async throws {
            toolsSeen.append(tool)
            installed = true
        }
        func update(tool: String, target: ConnectorTarget) async throws { installed = true }
        func uninstall(tool: String, target: ConnectorTarget) async throws { installed = false }
        func uninstallWithoutTool(target: ConnectorTarget) async throws { installed = false }
    }

    @Test func aConnectorThatRunsNoProgramInstallsChecksAndRemovesWithoutLookingForOne() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-folder-connector-\(UUID().uuidString)")
        let folder = dir.appendingPathComponent("home/.folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connector = FolderConnector(defaultFolder: folder)
        let model = AgentsSettingsModel(describeTerminal: Terminals().describe, agentsDir: dir, connectors: [connector])
        await model.refresh()
        #expect(setup(model).state == .status(.notInstalled))
        #expect(!setup(model).toolMissing)
        await setup(model).install()
        #expect(setup(model).state == .status(.ready))
        await setup(model).remove()
        #expect(setup(model).state == .status(.notInstalled))
        #expect(!connector.installed)
        #expect(!(await setup(model).details(folders: [])).contains("not found"))
        #expect(Set(connector.toolsSeen) == [ConnectorFolders.canonical(folder).path])
    }

    @Test func ultimateConnectsFromItsUserFolderWithNoUltimateCommandAnywhere() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-ultimate-settings-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".ultimate/projects"), withIntermediateDirectories: true)
        let connector = UltimateConnector(agentsDir: dir, pluginName: "keyscribe-dev", home: home, sources: UltimateConnectorTests.sources)
        let model = AgentsSettingsModel(describeTerminal: Terminals().describe, agentsDir: dir, connectors: [connector])
        await model.refresh()
        #expect(setup(model).state == .status(.notInstalled))
        #expect(!setup(model).toolMissing)
        await setup(model).install()
        #expect(setup(model).state == .status(.ready))
        #expect(!(await setup(model).details(folders: [])).contains("not found"))
    }
}

struct ClaudeCLITests {
    @Test func runReturnsTheStatusAndBothOutputStreams() {
        let (status, output) = ClaudeCLI.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], environment: [:])
        #expect(status == 3)
        #expect(output.contains("out"))
        #expect(output.contains("err"))
    }

    @Test func aCommandThatIgnoresTerminationIsKilled() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("ks-cli-\(UUID().uuidString)")
        let started = Date()
        let (status, _) = ClaudeCLI.run(["/bin/sh", "-c", "trap '' TERM; echo $$ > \(pidFile.path); exec sleep 30"], environment: [:], timeout: 0.5)
        #expect(status == -1)
        #expect(Date().timeIntervalSince(started) < 5)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func outputIsKeptWhenSomethingItStartedHoldsTheStreamOpen() {
        let started = Date()
        let (status, output) = ClaudeCLI.run(["/bin/sh", "-c", "echo done; sleep 20 & exit 0"], environment: [:])
        #expect(status == 0)
        #expect(output.contains("done"))
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func aCommandThatHangsIsStoppedAtItsTimeout() {
        let started = Date()
        let (status, output) = ClaudeCLI.run(["/bin/sleep", "5"], environment: [:], timeout: 0.3)
        #expect(status == -1)
        #expect(output.contains("did not finish"))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}

@MainActor
struct ClaudeConnectorCopyTests {
    @Test func afterRemovalOutsideTheAppOpenSessionsAreToldHowToStopListening() {
        #expect(ClaudeConnector(agentsDir: URL(fileURLWithPath: "/tmp"), pluginName: "keyscribe-dev", surfaces: .builtIn).copy.stillConnected(1) == "The connector was uninstalled outside \(Branding.appName), so 1 open conversation is still connected and keeps receiving what you say until you run /reload-plugins in it or restart it.")
        #expect(ClaudeConnector(agentsDir: URL(fileURLWithPath: "/tmp"), pluginName: "keyscribe-dev", surfaces: .builtIn).copy.stillConnected(3) == "The connector was uninstalled outside \(Branding.appName), so 3 open conversations are still connected and keep receiving what you say until you run /reload-plugins in each one or restart them.")
    }
}
