import Foundation
@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct CodingAgentsSettingsModelTests {
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
            if argv.contains("install") || argv.contains("update") { installed = ClaudeConnectorFiles.version }
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
        script: String? = ClaudeConnectorFiles.registerJS
    ) -> (CodingAgentsSettingsModel, CLI, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agents-model-\(UUID().uuidString)")
        let model = CodingAgentsSettingsModel(
            locateClaude: { claude }, run: cli.run, describeTerminal: terminals.describe, agentsDir: dir, pluginName: "keyscribe-dev",
            script: script)
        return (model, cli, dir)
    }

    @Test func aMissingConnectorIsUnavailableAndNeverRunsClaudeCode() async {
        let (model, cli, dir) = makeModel(script: nil)
        await model.refresh()
        #expect(model.connectors[0].state == .unavailable)
        await model.connectors[0].install()
        #expect(model.connectors[0].state == .unavailable)
        #expect(cli.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("claude-connector").path))
    }

    @Test func refreshReadsTheInstalledConnector() async {
        let cli = CLI()
        cli.installed = ClaudeConnectorFiles.version
        let (model, _, _) = makeModel(cli: cli)
        await model.refresh()
        #expect(model.connectors[0].state == .status(.ready))
    }

    @Test func removalWarningWaitsForConfirmedRemovalAndAnOpenConnection() async {
        let (model, cli, _) = makeModel()
        model.show([conversation("backend", pid: 1)], current: nil)
        #expect(!model.connectors[0].showsRemovalWarning)
        await model.refresh()
        #expect(model.connectors[0].showsRemovalWarning)
        model.show([], current: nil)
        #expect(!model.connectors[0].showsRemovalWarning)
        model.show([conversation("backend", pid: 1)], current: nil)
        cli.installed = ClaudeConnectorFiles.version
        await model.refresh()
        #expect(!model.connectors[0].showsRemovalWarning)
    }

    @Test func withoutClaudeCodeNothingRunsAndItSaysSo() async {
        let (model, cli, _) = makeModel(claude: nil)
        await model.refresh()
        await model.connectors[0].install()
        #expect(model.connectors[0].state == .toolNotFound)
        #expect(cli.calls.isEmpty)
    }

    @Test func installAddsTheMarketplaceAndPluginThenChecksAgain() async {
        let (model, cli, dir) = makeModel()
        await model.refresh()
        #expect(model.connectors[0].state == .status(.notInstalled))

        await model.connectors[0].install()
        #expect(cli.calls.map { Array($0.dropFirst()) }.contains(["plugin", "marketplace", "add", dir.appendingPathComponent("claude-connector").path]))
        #expect(cli.calls.map { Array($0.dropFirst()) }.contains(["plugin", "install", "keyscribe-dev@keyscribe-dev-local", "--scope", "user"]))
        #expect(model.connectors[0].state == .status(.ready))
        #expect(model.connectors[0].needsReload)
    }

    @Test func aFailedInstallShowsWhatClaudeSaid() async {
        let cli = CLI()
        cli.failing = ["install"]
        let (model, _, _) = makeModel(cli: cli)
        await model.connectors[0].install()
        #expect(model.connectors[0].state == .failed("boom: install"))
        #expect(!model.connectors[0].needsReload)
    }

    @Test func removeUninstallsAndForgetsTheReloadHint() async {
        let cli = CLI()
        cli.installed = ClaudeConnectorFiles.version
        let (model, _, _) = makeModel(cli: cli)
        await model.connectors[0].install()
        await model.connectors[0].remove()
        #expect(model.connectors[0].state == .status(.notInstalled))
        #expect(!model.connectors[0].needsReload)
    }

    @Test func removeRetiresTheInstallationAndLoadedConnectorsBeforeAnyUninstallCommand() async {
        let cli = CLI()
        let (model, _, dir) = makeModel(cli: cli)
        await model.connectors[0].install()
        #expect(ClaudeConnectorInstaller.currentInstallation(in: dir) != nil)
        var atRetire: (installation: String?, uninstalls: Int)?
        model.onRetire = { _ in atRetire = (ClaudeConnectorInstaller.currentInstallation(in: dir), cli.calls.filter { $0.contains("uninstall") }.count) }
        await model.connectors[0].remove()
        #expect(atRetire?.installation == nil)
        #expect(atRetire?.uninstalls == 0)
        #expect(cli.calls.contains { $0.contains("uninstall") })
    }

    @Test func aConnectorStillInClaudeCodeAfterAFailedRemovalIsShownAsUnfinishedUntilRemovedAgain() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await model.connectors[0].install()
        cli.failing = ["uninstall", "remove"]
        await model.connectors[0].remove()
        #expect(model.connectors[0].state == .removalUnfinished("boom: uninstall"))

        cli.failing = []
        await model.connectors[0].remove()
        #expect(model.connectors[0].state == .status(.notInstalled))
    }

    @Test func aConnectorInstalledBeforeInstallationsWereRecordedIsNotMistakenForAnUnfinishedRemoval() async {
        let cli = CLI()
        cli.installed = ClaudeConnectorFiles.version
        let (model, _, dir) = makeModel(cli: cli)
        await model.refresh()
        #expect(model.connectors[0].state == .status(.ready))
        try? ClaudeConnectorInstaller.disable(in: dir)
        await model.refresh()
        #expect(model.connectors[0].state == .removalUnfinished(nil))
    }

    @Test func anUninstallThatLeavesOnlyTheMarketplaceBehindStaysUnfinishedUntilRetried() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await model.connectors[0].install()
        cli.failing = ["remove"]
        await model.connectors[0].remove()
        #expect(cli.installed == nil && cli.marketplace)
        #expect(model.connectors[0].state == .removalUnfinished("boom: remove"))
        await model.refresh()
        #expect(model.connectors[0].state == .removalUnfinished(nil))

        cli.failing = []
        await model.connectors[0].remove()
        #expect(model.connectors[0].state == .status(.notInstalled))
    }

    @Test func withoutClaudeCodeAnInstalledConnectorCanStillBeUninstalledAndOffersTheCommandsToFinish() async {
        let cli = CLI()
        let (installed, _, dir) = makeModel(cli: cli)
        let model = CodingAgentsSettingsModel(
            locateClaude: { nil }, run: cli.run, describeTerminal: { _ in nil }, agentsDir: dir, pluginName: "keyscribe-dev")
        await model.refresh()
        #expect(model.connectors[0].manualUninstall.isEmpty)
        #expect(!model.connectors[0].canUninstallWithoutTool)
        #expect(model.connectors[0].manualUninstallLead == nil)

        await installed.connectors[0].install()
        await model.refresh()
        #expect(model.connectors[0].canUninstallWithoutTool)
        #expect(model.connectors[0].manualUninstallLead == "To remove the connector from Claude Code, run these in a terminal, then run /reload-plugins in each open session or restart it:")
        #expect(model.connectors[0].manualUninstall == [
            "claude plugin uninstall keyscribe-dev@keyscribe-dev-local --scope user",
            "claude plugin marketplace remove keyscribe-dev-local",
        ])

        await model.connectors[0].remove()
        #expect(!model.connectors[0].canUninstallWithoutTool)
        #expect(model.connectors[0].manualUninstall.count == 2)
        #expect(model.connectors[0].manualUninstallLead == "Disconnected from \(Branding.appName). Run these in a terminal to finish uninstalling, then run /reload-plugins in each open session or restart it:")
    }

    @Test func removeStillRetiresTheConnectorWhenClaudeCannotBeFound() async {
        let cli = CLI()
        let (installed, _, dir) = makeModel(cli: cli)
        await installed.connectors[0].install()
        let model = CodingAgentsSettingsModel(
            locateClaude: { nil }, run: cli.run, describeTerminal: { _ in nil }, agentsDir: dir, pluginName: "keyscribe-dev")
        var retired = false
        model.onRetire = { _ in retired = true }
        await model.connectors[0].remove()
        #expect(retired)
        #expect(ClaudeConnectorInstaller.currentInstallation(in: dir) == nil)
        #expect(model.connectors[0].state == .toolNotFound)
    }

    @Test func aRefreshDuringAnInstallLeavesItInProgressAndASecondInstallDoesNothing() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        await model.refresh()
        cli.holdNext("install")
        let installing = Task { await model.connectors[0].install() }
        await until { cli.calls.contains { $0.contains("install") } }
        #expect(model.connectors[0].operation == "Installing…")

        await model.refresh()
        await model.connectors[0].install()
        await model.connectors[0].remove()
        #expect(model.connectors[0].operation == "Installing…")
        #expect(cli.calls.filter { $0.contains("install") || $0.contains("uninstall") }.count == 1)

        cli.release()
        await installing.value
        #expect(model.connectors[0].operation == nil)
        #expect(model.connectors[0].state == .status(.ready))
    }

    @Test func aRefreshThatStartedBeforeAnInstallCannotUndoIt() async {
        let cli = CLI()
        let (model, _, _) = makeModel(cli: cli)
        cli.holdNext("list")
        let refreshing = Task { await model.refresh() }
        await until { !cli.calls.isEmpty }

        await model.connectors[0].install()
        #expect(model.connectors[0].state == .status(.ready))
        cli.release()
        await refreshing.value
        #expect(model.connectors[0].state == .status(.ready))
    }

    @Test func conversationsSayWhetherTheyCanReceiveBeforeWhatTheyAreDoing() {
        let (model, _, _) = makeModel()
        model.show([
            AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/keyscribe", handle: "keyscribe", state: .working, connectorLive: true),
            AgentConversation(id: "b", agent: "claude", pid: 2, cwd: "/src/chatplay", handle: "chatplay", state: .idle, connectorLive: false),
            AgentConversation(id: "c", agent: "claude", pid: 3, cwd: "/src/home", handle: "home", state: .idle, connectorLive: true),
        ], current: "a")
        #expect(model.rows == [
            .init(id: "a", number: 1, name: "keyscribe", folder: "/src/keyscribe", state: "Working", connected: true, current: true, agent: "claude"),
            .init(id: "b", number: 2, name: "chatplay", folder: "/src/chatplay", state: "Not connected", connected: false, current: false, agent: "claude"),
            .init(id: "c", number: 3, name: "home", folder: "/src/home", state: "Ready", connected: true, current: false, agent: "claude"),
        ])
        #expect(model.currentName == "keyscribe")
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
        model.show([conversation("backend", pid: 1)], current: nil, discoveryProblems: ["claude": "unreadable"])
        #expect(model.connectors[0].discoveryProblem == "unreadable")
        await until { model.rows.first?.terminal == "Ghostty" }
        #expect(model.rows.first?.terminal == "Ghostty")
        #expect(model.connectors[0].discoveryProblem == "unreadable")
        model.show([conversation("backend", pid: 1)], current: nil, discoveryProblems: [:])
        #expect(model.connectors[0].discoveryProblem == nil)
    }

    private func conversation(_ id: String, pid: Int, title: String? = nil) -> AgentConversation {
        AgentConversation(id: id, agent: "claude", pid: pid, cwd: "/src/\(id)", handle: id, state: .idle, connectorLive: true, title: title)
    }

    @Test func renameContextKeepsTheTitleWithItsConversationAsItChanges() {
        let (model, _, _) = makeModel()
        model.show([conversation("backend", pid: 1, title: "Fix the cache")], current: nil)
        #expect(model.rows.first?.title == "Fix the cache")
        model.show([conversation("backend", pid: 1, title: "Verify the cache")], current: nil)
        #expect(model.rows.first?.title == "Verify the cache")
        model.show([conversation("backend", pid: 1)], current: nil)
        #expect(model.rows.first?.title == nil)
    }

    @Test func firstInstructionGuidanceUsesTheConfiguredShortcutWithoutInventingOne() {
        let (model, _, _) = makeModel()
        model.show([conversation("backend", pid: 1)], current: nil)
        #expect(model.recipientGuidance(shortcut: "Fn (Globe)") == "Use Fn (Globe) and say \u{201C}backend, run the unit tests.\u{201D}")
        #expect(model.recipientGuidance(shortcut: nil) == "Start recording and say \u{201C}backend, run the unit tests.\u{201D}")
    }

    @Test func agentTypesAreShownOnlyWhenTheConversationListIsMixed() {
        let (model, _, _) = makeModel()
        let claude = conversation("backend", pid: 1)
        var codex = conversation("frontend", pid: 2)
        codex.agent = "codex"
        model.show([claude], current: nil)
        #expect(!model.showsAgentType)
        model.show([claude, codex], current: nil)
        #expect(model.showsAgentType)
        #expect(model.rows.map(\.agent) == ["claude", "codex"])
        model.show([codex], current: nil)
        #expect(!model.showsAgentType)
    }

    @Test func everyRowNamesItsTerminalIncludingSessionsThatShareOne() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty \u{00B7} herdr", 2: "Ghostty \u{00B7} herdr"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("a", pid: 1), conversation("b", pid: 2)], current: nil)
        await until { model.rows.allSatisfy { $0.terminal != nil } }
        #expect(model.rows.map(\.terminal) == ["Ghostty \u{00B7} herdr", "Ghostty \u{00B7} herdr"])

        terminals.byPid[3] = "cmux"
        model.show([conversation("a", pid: 1), conversation("b", pid: 2), conversation("c", pid: 3)], current: nil)
        await until { model.rows.last?.terminal != nil }
        #expect(model.rows.map(\.terminal) == ["Ghostty \u{00B7} herdr", "Ghostty \u{00B7} herdr", "cmux"])
        #expect(terminals.asked.sorted() == [1, 2, 3])
    }

    @Test func differentTerminalsStayWithTheirOwnConversation() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty", 2: "Terminal"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("a", pid: 1), conversation("b", pid: 2)], current: nil)
        await until { model.rows.allSatisfy { $0.terminal != nil } }
        #expect(model.rows.map(\.terminal) == ["Ghostty", "Terminal"])
    }

    @Test func aProcessIdReusedByALaterConversationIsDescribedAgain() async {
        let terminals = Terminals()
        terminals.byPid = [1: "Ghostty"]
        let (model, _, _) = makeModel(terminals: terminals)
        model.show([conversation("a", pid: 1)], current: nil)
        await until { model.rows.first?.terminal != nil }
        model.show([], current: nil)
        terminals.byPid[1] = "Terminal"
        model.show([conversation("b", pid: 1)], current: nil)
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
        ], current: nil)
        #expect(model.rows.map(\.folder) == ["/src/rsperko/keyscribe", "/src/other/keyscribe", "/src/chatplay", home])
    }

    @Test func aCurrentRecipientThatIsGoneIsNotShown() {
        let (model, _, _) = makeModel()
        model.show([AgentConversation(id: "b", agent: "claude", pid: 2, cwd: "/src/chatplay", handle: "chatplay", state: .idle, connectorLive: true)], current: "a")
        #expect(model.currentName == nil)
    }

    @Test func guidanceOnlyOffersWhatCanBeSaid() {
        let (model, _, _) = makeModel()
        let backend = AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true)
        let offline = AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: false)
        for (conversations, current, problem) in [
            ([backend], nil, nil), ([backend], "a", nil), ([offline], "a", nil), ([backend], nil, "unreadable"),
        ] as [([AgentConversation], String?, String?)] {
            model.show(conversations, current: current, namesProblem: problem)
            #expect(!model.recipientGuidance().contains("below"))
            #expect(!model.recipientGuidance().lowercased().contains("choose"))
        }
        model.show([backend], current: "a")
        #expect(model.recipientGuidance().contains("Instructions go here unless another conversation is in front of you"))
    }

    @Test func guidanceUsesRealConversationsAndExplainsAnEmptyList() {
        let (model, _, _) = makeModel()
        #expect(model.recipientGuidance().contains("Open a conversation"))
        #expect(!model.recipientGuidance().contains("keyscribe"))
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true),
        ], current: nil)
        #expect(model.recipientGuidance().contains("backend, run the unit tests"))
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true),
        ], current: "a", namesProblem: "unavailable")
        #expect(model.recipientGuidance().contains("session 1, run the unit tests"))
        #expect(model.recipientGuidance().contains("number shown while recording"))
        #expect(!model.recipientGuidance().contains("backend, run"))
    }

    @Test func theRenamePreviewAsksTheSameCheckTheRenameUses() {
        let (model, _, _) = makeModel()
        model.show([
            .init(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "backend", state: .idle, connectorLive: true),
        ], current: "a")
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
        ], current: nil)
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
        ], current: nil)
        #expect(model.renameExample("a", name: "Back End") == "Say \u{201C}back end, run the unit tests.\u{201D}")
        #expect(model.renameExample("a", name: "fix authentication retries")
            == "Say \u{201C}fix authentication retries, run the unit tests.\u{201D}")
        let short = try #require(AgentAddress.shorterSpokenName(for: "deploy the staging cluster", among: ["deploy the staging cluster", "backend", "fix authentication tests"]))
        #expect(model.renameExample("b", name: "deploy the staging cluster")
            == "Say \u{201C}deploy the staging cluster, run the unit tests.\u{201D} \u{201C}\(short), \u{2026}\u{201D} also works.")
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
        model.show([], current: nil, namesProblem: "names.json could not be read.")
        #expect(model.namesProblem == "names.json could not be read.")
        model.reloadNames()
        #expect(reloads == 1)
        model.show([], current: nil)
        #expect(model.namesProblem == nil)
        model.show([], current: nil, namesNotSaved: "names.json could not be written.")
        #expect(model.namesNotSaved == "names.json could not be written.")
        #expect(model.namesProblem == nil)
        model.show([], current: nil)
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
        #expect(model.renameProblem == "\u{201C}Session\u{201D} followed by a number is how you say a row, so it cannot be a name.")
    }
}

struct ClaudeCLITests {
    @Test func claudeIsFoundOnThePathFirstThenInTheUsualInstallPlaces() {
        let home = URL(fileURLWithPath: "/Users/me")
        let onPath = ClaudeCLI.locate(environment: ["PATH": "/custom/bin:/usr/bin"], home: home) { $0 == "/custom/bin/claude" || $0 == "/Users/me/.local/bin/claude" }
        #expect(onPath == "/custom/bin/claude")
        let usual = ClaudeCLI.locate(environment: ["PATH": "/usr/bin"], home: home) { $0 == "/Users/me/.local/bin/claude" }
        #expect(usual == "/Users/me/.local/bin/claude")
        #expect(ClaudeCLI.locate(environment: [:], home: home) { _ in false } == nil)
    }

    @Test func runReturnsTheStatusAndBothOutputStreams() {
        let (status, output) = ClaudeCLI.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"])
        #expect(status == 3)
        #expect(output.contains("out"))
        #expect(output.contains("err"))
    }

    @Test func aCommandThatIgnoresTerminationIsKilled() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("ks-cli-\(UUID().uuidString)")
        let started = Date()
        let (status, _) = ClaudeCLI.run(["/bin/sh", "-c", "trap '' TERM; echo $$ > \(pidFile.path); exec sleep 30"], timeout: 0.5)
        #expect(status == -1)
        #expect(Date().timeIntervalSince(started) < 5)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func outputIsKeptWhenSomethingItStartedHoldsTheStreamOpen() {
        let started = Date()
        let (status, output) = ClaudeCLI.run(["/bin/sh", "-c", "echo done; sleep 20 & exit 0"])
        #expect(status == 0)
        #expect(output.contains("done"))
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func aCommandThatHangsIsStoppedAtItsTimeout() {
        let started = Date()
        let (status, output) = ClaudeCLI.run(["/bin/sleep", "5"], timeout: 0.3)
        #expect(status == -1)
        #expect(output.contains("did not finish"))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}

@MainActor
struct ClaudeConnectorCopyTests {
    @Test func afterRemovalOutsideTheAppOpenSessionsAreToldHowToStopListening() {
        #expect(ClaudeConnector(agentsDir: URL(fileURLWithPath: "/tmp"), pluginName: "keyscribe-dev").copy.stillConnected(1) == "The connector was uninstalled outside \(Branding.appName), so 1 open session is still connected and keeps receiving what you say until you run /reload-plugins in it or restart it.")
        #expect(ClaudeConnector(agentsDir: URL(fileURLWithPath: "/tmp"), pluginName: "keyscribe-dev").copy.stillConnected(3) == "The connector was uninstalled outside \(Branding.appName), so 3 open sessions are still connected and keep receiving what you say until you run /reload-plugins in each one or restart them.")
    }
}
