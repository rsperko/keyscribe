import Foundation
import Testing
@testable import KeyScribeKit

struct OmpAgentTests {
    let home = "/Users/a"

    private func process(
        _ pid: Int, parent: Int = 1, name: String = "omp", arguments: [String], environment: [String: String] = [:],
        tty: String? = "/dev/ttys018", executable: String? = nil
    ) -> TerminalProcess {
        TerminalProcess(
            pid: pid, parent: parent, tty: tty, arguments: arguments, environment: environment,
            executable: executable ?? "/Users/a/.local/bin/\(name)", app: nil, directory: "/Users/a/src/atlas", startedAt: 100,
            argumentsReadable: true)
    }

    private let bunScript = "/Users/a/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"
    private let piScript = "/Users/a/.nvm/versions/node/v24/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"

    private var resolve: (String) -> AgentProcesses.Resolved? {
        { [bunScript, piScript] path in
            [
                "/Users/a/.bun/bin/omp": AgentProcesses.Resolved(path: bunScript, executable: true),
                "/Users/a/.nvm/versions/node/v24/bin/pi": AgentProcesses.Resolved(path: piScript, executable: true),
            ][path]
        }
    }

    @Test func theKindIsNamedAsOmpWritesIt() {
        #expect(AgentKind.omp.id == "omp")
        #expect(AgentKind.omp.displayName == "omp")
        #expect(AgentKind.omp.reloadCommand == nil)
    }

    @Test func theBinaryInstallIsFoundWithItsDefaultFolder() {
        let found = AgentProcesses.classify([process(10, arguments: ["omp"])], rule: .omp, home: home)
        #expect(found.candidates.map(\.pid) == [10])
        #expect(found.candidates.map(\.agent) == ["omp"])
        #expect(found.candidates.map(\.setup) == ["/Users/a/.omp/agent"])
    }

    @Test func theSetupVariableMovesTheDefaultProfilesFolder() {
        let found = AgentProcesses.classify(
            [process(11, arguments: ["omp"], environment: ["PI_CODING_AGENT_DIR": "~/omp-work"])], rule: .omp, home: home)
        #expect(found.candidates.map(\.setup) == ["/Users/a/omp-work"])
    }

    @Test func theBunInstallIsFoundByItsPackage() {
        let found = AgentProcesses.classify(
            [process(12, name: "bun", arguments: ["bun", "/Users/a/.bun/bin/omp"], executable: "/opt/homebrew/bin/bun")],
            rule: .omp, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [12])
        #expect(found.candidates.first?.runtime == "/opt/homebrew/bin/bun")
    }

    @Test func theWorkerBrokerChildIsNotAConversation() {
        let found = AgentProcesses.classify([
            process(18993, arguments: ["omp"]),
            process(20241, parent: 18993, arguments: ["/Users/a/.local/bin/omp", "__omp_worker_daemon_broker"], tty: nil),
        ], rule: .omp, home: home)
        #expect(found.candidates.map(\.pid) == [18993])
    }

    @Test func ompAndPiRunningSideBySideAreEachListedAsThemselves() {
        let running = [
            process(30, name: "bun", arguments: ["bun", "/Users/a/.bun/bin/omp"], executable: "/opt/homebrew/bin/bun"),
            process(31, name: "node", arguments: ["node", "/Users/a/.nvm/versions/node/v24/bin/pi"], executable: "/usr/local/bin/node"),
            process(32, arguments: ["omp"]),
            process(33, name: "pi", arguments: ["pi"]),
        ]
        #expect(AgentProcesses.classify(running, rule: .omp, home: home, resolve: resolve).candidates.map(\.pid) == [30, 32])
        #expect(AgentProcesses.classify(running, rule: .pi, home: home, resolve: resolve).candidates.map(\.pid) == [31, 33])
    }

    @Test func aNamedProfileNeverReportsTheDefaultFolder() {
        let found = AgentProcesses.classify([
            process(40, arguments: ["omp", "--profile", "work"]),
            process(41, arguments: ["omp", "--profile=work"]),
            process(42, arguments: ["omp"], environment: ["OMP_PROFILE": "work"]),
            process(43, arguments: ["omp"], environment: ["PI_PROFILE": "work"]),
            process(44, arguments: ["omp", "--profile", "work"], environment: ["PI_CODING_AGENT_DIR": "/Users/a/omp-work"]),
            process(45, arguments: ["omp"], environment: ["OMP_PROFILE": ""]),
        ], rule: .omp, home: home)
        #expect(found.candidates.map(\.pid) == [40, 41, 42, 43, 44, 45])
        #expect(found.candidates.map(\.setup) == [nil, nil, nil, nil, nil, "/Users/a/.omp/agent"])
        #expect(found.setups == ["/Users/a/.omp/agent"])
    }

    @Test func aProfileIsSeenWhenARuntimeStartsOmp() {
        let found = AgentProcesses.classify(
            [process(46, name: "bun", arguments: ["bun", "/Users/a/.bun/bin/omp", "--profile", "work"], executable: "/opt/homebrew/bin/bun")],
            rule: .omp, home: home, resolve: resolve)
        #expect(found.candidates.map(\.setup) == [nil])
    }

    @Test func theVersionIsReadFromOmpsOwnOutput() {
        #expect(OmpCLI.version(in: "omp/18.22.2\n") == [18, 22, 2])
        #expect(OmpCLI.version(in: "omp v18.22.2") == [18, 22, 2])
        #expect(OmpCLI.version(in: "omp/19.0.0-beta.1") == [19, 0, 0])
        #expect(OmpCLI.version(in: "pi/18.22.2") == nil)
        #expect(OmpCLI.version(in: "18.22.2") == [18, 22, 2])
        #expect(OmpCLI.version(in: "18.22") == nil)
        #expect(OmpCLI.version(in: "Error: Bun runtime must be >= 1.4.4 (found v1.4.2)") == nil)
        #expect(OmpCLI.version(in: "") == nil)
    }

    @Test func theFloorIsTheVersionTheConnectorWasProvenOn() {
        #expect(OmpCLI.minimumVersion == [18, 22, 2])
    }

    @Test func theTurnedOffModulesAreReadFromOmpsConfigAnswer() {
        let listed = #"{"key":"disabledExtensions","value":["extension-module:other","extension-module:keyscribe-dev-omp","tool:x"],"type":"array"}"#
        #expect(OmpCLI.disabledModules(listed) == ["other", "keyscribe-dev-omp"])
        #expect(OmpCLI.disabledModules(#"{"key":"disabledExtensions","value":[],"type":"array"}"#) == [])
    }

    @Test func anAnswerThatIsNotOmpsConfigIsUnreadableNeverEmpty() {
        #expect(OmpCLI.disabledModules("error: something") == nil)
        #expect(OmpCLI.disabledModules(#"{"key":"disabledExtensions","value":"keyscribe","type":"string"}"#) == nil)
        #expect(OmpCLI.disabledModules(#"{"key":"other","value":[]}"#) == nil)
        #expect(OmpCLI.disabledModules("") == nil)
    }
}
