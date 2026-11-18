import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct OmpConnectorTests {
    final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var _argv: [[String]] = []
        var disabled: [String] = []
        var answer: ToolCLI.Ran?
        var argv: [[String]] { lock.withLock { _argv } }

        func execute(_ argv: [String]) -> ToolCLI.Ran {
            let (disabled, answer) = lock.withLock {
                _argv.append(argv)
                return (self.disabled, self.answer)
            }
            if let answer { return answer }
            let names = disabled.map { "\"extension-module:\($0)\"" }.joined(separator: ",")
            return ToolCLI.Ran(end: .exited(0), output: Data(#"{"key":"disabledExtensions","value":[\#(names)],"type":"array"}"#.utf8))
        }
    }

    private struct Made {
        let omp: ExtensionConnector
        let pi: ExtensionConnector
        let home: URL
        let profile: URL
        let tools: ToolEnvironment
        var folder: URL { home.appendingPathComponent(".omp/agent") }
    }

    private func make(version: String = "omp/18.22.2\n", runs: Runs = Runs()) -> Made {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-omp-conn-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let tools = ToolEnvironment(
            appEnvironment: ["PATH": "/test-bin", "PI_CODING_AGENT_DIR": "/elsewhere", "OMP_PROFILE": "work"], shell: "/bin/zsh",
            execute: { argv, _, _, _, _ in runs.execute(argv) }, isExecutable: { $0 == "/test-bin/omp" })
        let agents = root.appendingPathComponent("agents")
        let omp = ExtensionConnector(
            agent: .omp, version: { _ in ToolCheck.judge(.exited(0), output: version) }, tools: tools,
            agentsDir: agents, pluginName: "keyscribe-dev", surfaces: .builtIn, home: home)
        let pi = ExtensionConnector(
            agent: .pi, version: { _ in ToolCheck.judge(.exited(0), output: "1.5.0\n") }, tools: tools,
            agentsDir: agents, pluginName: "keyscribe-dev", surfaces: .builtIn, home: home)
        return Made(omp: omp, pi: pi, home: home, profile: root.appendingPathComponent("profile/agent"), tools: tools)
    }

    private func target(_ folder: URL, isDefault: Bool = true, installation: String = "id-omp") -> ConnectorTarget {
        ConnectorTarget(folder: folder, isDefault: isDefault, installation: installation)
    }

    private let query = ["config", "get", "disabledExtensions", "--json"]

    @Test func theDefaultFolderIsOmpsOwnAndTheToolIsOmp() {
        let made = make()
        #expect(made.omp.defaultFolder.path == made.folder.path)
        #expect(made.omp.kind == .omp)
        #expect(made.omp.toolProgram == "omp")
        #expect(made.omp.folderVariable == "PI_CODING_AGENT_DIR")
    }

    @Test func theInstalledConnectorIsTheSharedOneMarkedForOmpInAFolderOfItsOwn() async throws {
        let made = make()
        try await made.omp.install(tool: "/test-bin/omp", target: target(made.folder))
        let code = try String(contentsOf: made.folder.appendingPathComponent("extensions/keyscribe-dev-omp/index.ts"), encoding: .utf8)
        #expect(code.contains("const installedFor: string | null = \"omp\""))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: made.folder.appendingPathComponent("extensions/keyscribe-dev-omp/keyscribe.json"))) as? [String: Any]
        #expect(config?["plugin"] as? String == "keyscribe-dev")
        #expect(await made.omp.check(tool: "/test-bin/omp", target: target(made.folder)) == .status(.ready))
        #expect(made.omp.manualUninstall(for: target(made.folder)).first?.hasSuffix("/extensions/keyscribe-dev-omp") == true)
    }

    @Test func piAndOmpInstalledInOneFolderKeepTheirOwnConnectorsAndRemoveOnlyTheirOwn() async throws {
        let made = make()
        let shared = made.home.appendingPathComponent("shared-agent")
        let piTarget = ConnectorTarget(folder: shared, isDefault: false, installation: "id-pi")
        let ompTarget = target(shared, isDefault: false)
        try await made.pi.install(tool: "/test-bin/pi", target: piTarget)
        try await made.omp.install(tool: "/test-bin/omp", target: ompTarget)
        #expect(await made.pi.check(tool: "/test-bin/pi", target: piTarget) == .status(.ready))
        #expect(await made.omp.check(tool: "/test-bin/omp", target: ompTarget) == .status(.ready))
        try await made.pi.install(tool: "/test-bin/pi", target: piTarget)
        #expect(await made.omp.check(tool: "/test-bin/omp", target: ompTarget) == .status(.ready))
        try await made.omp.uninstall(tool: "/test-bin/omp", target: ompTarget)
        #expect(!made.omp.hasFiles(in: ompTarget))
        #expect(made.pi.hasFiles(in: piTarget))
        #expect(await made.pi.check(tool: "/test-bin/pi", target: piTarget) == .status(.ready))
    }

    @Test func aConnectorTurnedOffInOmpIsSeenThroughOmpsOwnConfigCommandForThatFolderAlone() async throws {
        let runs = Runs()
        let made = make(runs: runs)
        try await made.omp.install(tool: "/test-bin/omp", target: target(made.folder))
        runs.disabled = ["keyscribe-dev-omp"]
        #expect(await made.omp.check(tool: "/test-bin/omp", target: target(made.folder)) == .status(.disabled))
        #expect(runs.argv.last == ["/usr/bin/env", "-u", "OMP_PROFILE", "-u", "PI_PROFILE", "-u", "PI_CODING_AGENT_DIR", "/test-bin/omp"] + query)
        runs.disabled = ["keyscribe-dev"]
        try await made.omp.install(tool: "/test-bin/omp", target: target(made.profile, isDefault: false))
        #expect(await made.omp.check(tool: "/test-bin/omp", target: target(made.profile, isDefault: false)) == .status(.ready))
        #expect(runs.argv.last == [
            "/usr/bin/env", "-u", "OMP_PROFILE", "-u", "PI_PROFILE", "PI_CODING_AGENT_DIR=\(made.profile.path)", "/test-bin/omp",
        ] + query)
    }

    @Test func ompIsAskedOnlyAboutAConnectorThatIsInPlace() async throws {
        let runs = Runs()
        let made = make(runs: runs)
        #expect(await made.omp.check(tool: "/test-bin/omp", target: target(made.folder)) == .status(.notInstalled))
        try await made.omp.install(tool: "/test-bin/omp", target: target(made.folder))
        let config = made.folder.appendingPathComponent("extensions/keyscribe-dev-omp/keyscribe.json")
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] ?? [:]
        settings["version"] = "0.1.0-old"
        try JSONSerialization.data(withJSONObject: settings).write(to: config)
        #expect(await made.omp.check(tool: "/test-bin/omp", target: target(made.folder)) == .status(.outdated(installed: "0.1.0-old")))
        #expect(runs.argv.isEmpty)
    }

    @Test func aConfigOmpCannotAnswerLeavesTheConnectorInstalledButUnconfirmedNeverReady() async throws {
        let runs = Runs()
        let made = make(runs: runs)
        try await made.omp.install(tool: "/test-bin/omp", target: target(made.folder))
        let answers: [(ToolCLI.Ran, String)] = [
            (ToolCLI.Ran(end: .exited(1), output: Data("config.yml: bad indent".utf8)), "exit code 1: config.yml: bad indent"),
            (ToolCLI.Ran(end: .timedOut(10), output: Data()), "did not finish within 10 seconds"),
            (ToolCLI.Ran(end: .exited(0), output: Data("not json".utf8)), "can\u{2019}t read"),
        ]
        for (answer, said) in answers {
            runs.answer = answer
            let state = await made.omp.check(tool: "/test-bin/omp", target: target(made.folder))
            guard case .unconfirmed(let reason) = state else {
                Issue.record("\(state)")
                continue
            }
            #expect(reason.contains("turned off"), "\(reason)")
            #expect(reason.contains(said), "\(reason)")
        }
    }

    @Test func aConfigOmpCannotAnswerOffersTryAgainAndStartupNeverRewritesTheConnectorForIt() async throws {
        let runs = Runs()
        let made = make(runs: runs)
        let model = AgentConnectorModel(made.omp, registry: ConnectorSetupRegistry(directory: made.home.appendingPathComponent("registry")), tools: made.tools)
        let setup = try #require(model.setups.first { $0.isDefault })
        await setup.install()
        #expect(setup.state == .status(.ready))
        let script = made.folder.appendingPathComponent("extensions/keyscribe-dev-omp/index.ts")
        let written = try FileManager.default.attributesOfItem(atPath: script.path)[.systemFileNumber] as? Int
        runs.answer = ToolCLI.Ran(end: .timedOut(10), output: Data())
        await model.maintain()
        guard case .unconfirmed = setup.state else {
            Issue.record("\(setup.state)")
            return
        }
        #expect(setup.isInstalled)
        #expect(setup.statusText == "Something went wrong")
        #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.systemFileNumber] as? Int == written)
        runs.answer = nil
        await setup.retry()
        #expect(setup.state == .status(.ready))
        #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.systemFileNumber] as? Int == written)
    }

    @Test func anOmpOlderThanTheFloorIsNamedTooOld() async {
        let made = make(version: "omp/18.21.9\n")
        let state = await made.omp.check(tool: "/test-bin/omp", target: target(made.folder))
        #expect(state == .toolTooOld("18.21.9"))
        #expect(made.omp.copy.toolTooOldAdvice("18.21.9").contains("18.22.2"))
    }

    @Test func theCopyNamesNoReloadCommandOmpDoesNotHaveAndSaysHowToReopenTheConversation() {
        let made = make()
        let copy = made.omp.copy
        #expect(made.omp.kind.reloadCommand == nil)
        #expect(made.omp.kind.resumeCommand == "omp --resume")
        #expect(copy.reloadHint == "Already running omp here? Quit each open conversation and reopen it with omp --resume to connect it.")
        #expect(copy.uninstallMessage.contains("Each open conversation unloads the connector when you quit it and reopen it with omp --resume."))
        #expect(copy.manualUninstallLead == "To remove the connector from omp, delete its folder in a terminal, then quit each open conversation and reopen it with omp --resume:")
        #expect(copy.stillConnected(1).hasSuffix("until you quit it and reopen it with omp --resume."))
        #expect(copy.stillConnected(2).hasSuffix("until you quit them and reopen them with omp --resume."))
        for text in [copy.reloadHint, copy.uninstallMessage, copy.manualUninstallLead, copy.manualUninstallAfterDisconnect, copy.stillConnected(2)] {
            #expect(!text.contains("/reload"), "\(text)")
        }
    }
}
