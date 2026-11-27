import Foundation
import KeyScribeKit

@MainActor
enum ConnectorCLI {
    enum Action: String, CaseIterable { case install, uninstall, status }

    struct Outcome: Equatable {
        var code: Int32
        var lines: [String]
    }

    nonisolated static let flag = "--connector"

    static func run(
        action: Action, agent: String, folder: URL?, tool: String?, connectors: [any AgentConnector], agentsDir: URL,
        bridgeAnswers: (URL) -> Bool = ConnectorCLI.bridgeAnswers
    ) async -> Outcome {
        guard let connector = connectors.first(where: { $0.kind.id == agent }) else {
            return Outcome(code: 2, lines: ["connector: no agent is named \u{201C}\(agent)\u{201D}. Known: \(connectors.map(\.kind.id).joined(separator: ", "))"])
        }
        if action != .status, bridgeAnswers(agentsDir.appendingPathComponent("bridge.sock")) {
            return Outcome(code: 1, lines: [
                "connector: the \(Branding.appName) using \(agentsDir.deletingLastPathComponent().path) is running. Quit it first: it reads its connectors only at launch.",
            ])
        }
        let registry = ConnectorSetupRegistry(directory: agentsDir)
        if let problem = registry.problem { return Outcome(code: 1, lines: ["connector: \(problem)"]) }
        let chosen = ConnectorFolders.canonical(folder ?? connector.defaultFolder)
        let setup = ConnectorSetupModel(
            folder: chosen, isDefault: ConnectorFolders.canonical(connector.defaultFolder) == chosen, connector: connector, registry: registry,
            retire: { _ in })
        if let tool, let problem = await setup.choose(tool: URL(fileURLWithPath: tool)) {
            return Outcome(code: 1, lines: ["connector: \(problem)"])
        }
        let succeeded: Bool
        switch action {
        case .status:
            await setup.refresh()
            succeeded = true
        case .install:
            await setup.install()
            succeeded = setup.state == .status(.ready)
        case .uninstall:
            await setup.remove()
            succeeded = setup.state == .status(.notInstalled)
        }
        let enrolled = registry.setups?.setup(agent: agent, folder: chosen.path).map { $0.removing ? "removing" : "enrolled" } ?? "not enrolled"
        return Outcome(code: succeeded ? 0 : 1, lines: ["\(agent)\t\(chosen.path)\t\(describe(setup.state, copy: connector.copy))\t\(enrolled)"])
    }

    static func describe(_ state: AgentConnectorModel.State, copy: AgentConnectorCopy) -> String {
        guard case .toolTooOld(let version) = state, case let advice = copy.toolTooOldAdvice(version), !advice.isEmpty else { return describe(state) }
        return "\(describe(state)) (\(advice))"
    }

    static func describe(_ state: AgentConnectorModel.State) -> String {
        switch state {
        case .status(let status): "\(status)"
        case .failed(let message): "failed: \(message)"
        case .broken(let message): "broken: \(message)"
        case .needsUser(let message): "needs you: \(message)"
        case .unconfirmed(let message): "unconfirmed: \(message)"
        case .removalUnfinished(let message): "removal unfinished\(message.map { ": " + $0 } ?? "")"
        case .toolTooOld(let version): "tool too old: \(version)"
        case .toolNotWorking(let check): "tool not working: \(String(describing: check))"
        case .toolNotFound: "tool not found"
        case .unavailable: "unavailable"
        case .checking: "checking"
        }
    }

    nonisolated static func bridgeAnswers(_ socket: URL) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0
    }
}
