import Foundation
import Testing
@testable import KeyScribeKit

struct AgentModeTests {
    @Test func agentOutputRoundTripsWithItsTable() throws {
        var mode = Mode(id: "coding-agent", name: "Coding agent")
        mode.output = .agent
        mode.agent = .init(target: .handle("backend"), delivery: .draft)
        let decoded = try ModeStore.decode(from: ModeStore.encode(mode), id: "coding-agent")
        #expect(decoded.output == .agent)
        #expect(decoded.agent == .init(target: .handle("backend"), delivery: .draft))
    }

    @Test func agentTableDefaultsToFocusedAndSendAfterSpeaking() throws {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Coding agent"
        output = "agent"
        """
        let mode = try ModeStore.decode(from: toml, id: "coding-agent")
        #expect(mode.agent == .init(target: .focused, delivery: .submit))
    }

    @Test(arguments: [
        ("focused", Mode.Agent.Target.focused),
        ("current", .current),
        ("ask", .ask),
        ("keyscribe blue", .handle("keyscribe blue")),
    ])
    func targetSpellings(written: String, expected: Mode.Agent.Target) throws {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Coding agent"
        output = "agent"
        [agent]
        target = "\(written)"
        """
        #expect(try ModeStore.decode(from: toml, id: "coding-agent").agent.target == expected)
    }

    @Test func anEmptyHandleIsRejected() {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Coding agent"
        output = "agent"
        [agent]
        target = "  "
        """
        #expect(throws: ConfigError.self) { try ModeStore.decode(from: toml, id: "coding-agent") }
    }

    @Test func nonAgentModesDoNotWriteTheAgentTable() throws {
        let toml = try ModeStore.encode(Mode(id: "plain", name: "Plain"))
        #expect(!toml.contains("[agent]"))
    }

    @Test func theAgentTableIsAKnownKey() throws {
        var mode = Mode(id: "coding-agent", name: "Coding agent")
        mode.output = .agent
        mode.agent = .init(target: .current, delivery: .draft)
        #expect(ModeStore.unknownKeys(in: try ModeStore.encode(mode)).isEmpty)
    }

    @Test func codingAgentsIsAnOptInFlag() {
        #expect(Feature.allCases.contains(.codingAgents))
        #expect(!Settings.defaults.features.isEnabled(.codingAgents))
    }
}
