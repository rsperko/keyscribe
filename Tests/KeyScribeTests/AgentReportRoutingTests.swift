import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentReportRoutingTests {
    private func registry() throws -> (ConnectorSetupRegistry, ConnectorSetup) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let setups = ConnectorSetupRegistry(directory: dir)
        let setup = try setups.grant(agent: AgentHostTests.kind.id, folder: "/Users/me/.example")
        return (setups, setup)
    }

    private func reporting(_ decode: (@Sendable (Data, String) -> [AgentEvent]?)?) -> AgentHostIntegration {
        var integration = AgentHostIntegration(kind: AgentHostTests.kind, make: { AgentHostTests.FakeHost() })
        integration.report = decode
        return integration
    }

    @Test func aReportIsDecodedByItsAgentAgainstTheFolderItsInstallationWasEnrolledFor() throws {
        let (setups, setup) = try registry()
        let route = AgentRuntime.reports(hosts: [reporting { body, folder in
            [.turnStarted(session: "\(folder)|\(String(decoding: body, as: UTF8.self))", turn: "u", prompt: "d")]
        }], setups: setups)
        guard case .events(let events) = route(AgentHostTests.kind.id, setup.installation, Data("body".utf8)) else {
            Issue.record("not decoded")
            return
        }
        #expect(events == [.turnStarted(session: "/Users/me/.example|body", turn: "u", prompt: "d")])
    }

    @Test func anAgentWithoutADecoderOrAnInstallationEnrolledForAnotherAgentIsRefused() throws {
        let (setups, setup) = try registry()
        let silent = AgentRuntime.reports(hosts: [reporting(nil)], setups: setups)
        let decoding = AgentRuntime.reports(hosts: [reporting { _, _ in [] }], setups: setups)
        #expect(isRefused(silent(AgentHostTests.kind.id, setup.installation, Data())))
        #expect(isRefused(decoding("other", setup.installation, Data())))
        #expect(isRefused(decoding(AgentHostTests.kind.id, "unknown", Data())))
    }

    @Test func aBodyItsDecoderCannotReadIsMalformed() throws {
        let (setups, setup) = try registry()
        let route = AgentRuntime.reports(hosts: [reporting { _, _ in nil }], setups: setups)
        guard case .malformed = route(AgentHostTests.kind.id, setup.installation, Data()) else {
            Issue.record("not malformed")
            return
        }
    }

    @Test func anInstallationBeingRemovedIsRefused() throws {
        let (setups, setup) = try registry()
        try setups.beginRemoval(agent: setup.agent, folder: setup.folder)
        let route = AgentRuntime.reports(hosts: [reporting { _, _ in [] }], setups: setups)
        #expect(isRefused(route(AgentHostTests.kind.id, setup.installation, Data())))
    }

    private func isRefused(_ report: AgentBridgeServer.Report) -> Bool {
        if case .refused = report { return true }
        return false
    }
}
