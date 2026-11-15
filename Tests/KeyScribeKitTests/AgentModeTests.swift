import Foundation
import Testing
@testable import KeyScribeKit

struct AgentModeTests {
    @Test func agentOutputRoundTripsWithItsTable() throws {
        var mode = Mode(id: "agent", name: "Agent")
        mode.output = .agent
        mode.agent = .init(target: .handle("backend"))
        let decoded = try ModeStore.decode(from: ModeStore.encode(mode), id: Mode.agentModeId)
        #expect(decoded.output == .agent)
        #expect(decoded.agent == .init(target: .handle("backend")))
    }

    @Test func agentTableDefaultsToCurrent() throws {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Agent"
        output = "agent"
        """
        let mode = try ModeStore.decode(from: toml, id: Mode.agentModeId)
        #expect(mode.agent == .init(target: .current))
    }

    @Test func anAgentTableWithoutATargetDefaultsToCurrent() throws {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Agent"
        output = "agent"
        [agent]
        """
        #expect(try ModeStore.decode(from: toml, id: Mode.agentModeId).agent == .init(target: .current))
    }

    @Test func anOlderFocusedTargetIsReadAsCurrentAndWrittenAsCurrent() throws {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Agent"
        output = "agent"
        [agent]
        target = "focused"
        """
        let mode = try ModeStore.decode(from: toml, id: Mode.agentModeId).systemNormalized()
        #expect(mode.agent.target == .current)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ModeStore.write(mode, to: dir)
        #expect(ModeStore.loadAll(in: dir).first { $0.id == Mode.agentModeId }?.agent.target == .current)
        #expect(!(try ModeStore.encode(mode)).contains("focused"))
    }

    @Test(arguments: [
        ("focused", Mode.Agent.Target.current),
        ("current", .current),
        ("ask", .ask),
        ("keyscribe blue", .handle("keyscribe blue")),
    ])
    func targetSpellings(written: String, expected: Mode.Agent.Target) throws {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Agent"
        output = "agent"
        [agent]
        target = "\(written)"
        """
        #expect(try ModeStore.decode(from: toml, id: Mode.agentModeId).agent.target == expected)
    }

    @Test func anEmptyHandleIsRejected() {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Agent"
        output = "agent"
        [agent]
        target = "  "
        """
        #expect(throws: ConfigError.self) { try ModeStore.decode(from: toml, id: Mode.agentModeId) }
    }

    @Test func nonAgentModesDoNotWriteTheAgentTable() throws {
        let toml = try ModeStore.encode(Mode(id: "plain", name: "Plain"))
        #expect(!toml.contains("[agent]"))
    }

    @Test func theAgentTableIsAKnownKey() throws {
        var mode = Mode(id: "agent", name: "Agent")
        mode.output = .agent
        mode.agent = .init(target: .handle("backend"))
        #expect(ModeStore.unknownKeys(in: try ModeStore.encode(mode)).isEmpty)
    }

    @Test func agentsIsAnOptInFlag() {
        #expect(Feature.allCases.contains(.agents))
        #expect(!Settings.defaults.features.isEnabled(.agents))
    }

    private func tempModesDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-modes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func onlyTheBuiltInModeSendsToAgents() {
        let toml = """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Talk"
        output = "agent"
        """
        #expect(throws: ConfigError.self) { try ModeStore.decode(from: toml, id: "talk") }
    }

    @Test func theBuiltInModeExistsOnlyWhileTheFeatureIsOn() throws {
        let dir = tempModesDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        ModeStore.ensureSystemModes(in: dir, agents: false)
        #expect(!ModeStore.loadAll(in: dir).contains { $0.id == Mode.agentModeId })

        ModeStore.ensureSystemModes(in: dir, agents: true)
        ModeStore.ensureSystemModes(in: dir, agents: true)
        let agentModes = ModeStore.loadAll(in: dir).filter { $0.output == .agent }
        #expect(agentModes.map(\.id) == [Mode.agentModeId])
        let mode = try #require(agentModes.first)
        #expect(mode.isSystem)
        #expect(mode.name == "Agent")
        #expect(mode.triggerKeys.isEmpty)
        #expect(mode.agent == .init(target: .current))
        #expect(mode.commands == .init(liveEdits: true, privacy: false, numbers: true))

        let all = ModeStore.loadAll(in: dir)
        #expect(Mode.visible(all, voiceCommands: false, agents: false).allSatisfy { $0.id != Mode.agentModeId })
        #expect(Mode.visible(all, voiceCommands: false, agents: true).contains { $0.id == Mode.agentModeId })
    }

    @Test func theBuiltInModeKeepsOnlyWhatTheUserMayChange() {
        var edited = Mode.agentMode
        edited.name = "Renamed"
        edited.output = .cursor
        edited.source = .selection
        edited.trailing = .space
        edited.triggerPhrases = ["to the agent"]
        edited.constraints = [.init(bundleId: "com.example")]
        edited.triggerKeys = [.init(key: "control+/")]
        edited.enabled = false
        edited.agent = .init(target: .handle("backend"))
        edited.dictionary = .init(includeGlobal: false, words: ["herdr"])
        edited.replacements = .init(includeGlobal: false, rules: [.init(heard: "a", replace: "b", regex: false)])
        edited.aiRewrite = .init(
            connection: "c", prompt: "Tidy it.", fragments: ["style"], context: .init(app: true, precedingText: true))
        edited.commands = .init(liveEdits: false, privacy: true, numbers: false)
        edited.excludeFromHistory = true

        let normalized = edited.systemNormalized()
        #expect(normalized.name == "Agent")
        #expect(normalized.output == .agent)
        #expect(normalized.source == .dictation)
        #expect(normalized.trailing == .none)
        #expect(normalized.triggerPhrases.isEmpty)
        #expect(normalized.constraints.isEmpty)
        #expect(normalized.triggerKeys == edited.triggerKeys)
        #expect(normalized.enabled == false)
        #expect(normalized.agent == edited.agent)
        #expect(normalized.dictionary == edited.dictionary)
        #expect(normalized.replacements == edited.replacements)
        #expect(normalized.aiRewrite == .init(connection: "c", prompt: "Tidy it.", fragments: ["style"]))
        #expect(normalized.commands == .init(liveEdits: true, privacy: true, numbers: true))
        #expect(normalized.excludeFromHistory)
    }
}
