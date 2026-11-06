import Foundation
import KeyScribeKit

struct AgentConnectorCopy {
    var help: String
    var reloadHint: String
    var uninstallTitle: String
    var uninstallMessage: String
    var noSessions: String
    var toolNotFoundLabel: String
    var toolNotFoundAdvice: String
    var unavailable: String
    var disabledLabel: String
    var disabledAdvice: String
    var removalUnfinishedAdvice: String
    var listUnreadable: String
    var noReason: String
    var manualUninstallLead: String
    var manualUninstallAfterDisconnect: String
    var stillConnected: (Int) -> String
    var toolTooOldLabel = ""
    var toolTooOldAdvice: (String) -> String = { _ in "" }
}

struct AgentConnectorError: Error {
    var message: String
}

@MainActor
protocol AgentConnector: AnyObject {
    var kind: AgentKind { get }
    var copy: AgentConnectorCopy { get }
    var isBundled: Bool { get }
    var hasFiles: Bool { get }
    var wasRemoved: Bool { get }
    var manualUninstall: [String] { get }
    func locateTool() -> String?
    func check(tool: String) async -> AgentConnectorModel.State
    func install(tool: String) async throws
    func update(tool: String) async throws
    func uninstall(tool: String) async throws
    func disable() throws
}

@MainActor
final class AgentConnectorModel: ObservableObject, Identifiable {
    enum State: Equatable {
        case checking
        case toolNotFound
        case toolTooOld(String)
        case unavailable
        case status(AgentConnectorStatus)
        case removalUnfinished(String?)
        case failed(String)
    }

    let connector: any AgentConnector
    nonisolated let id: String
    @Published private(set) var state: State = .checking
    @Published private(set) var operation: String?
    @Published private(set) var needsReload = false
    @Published var sessions = 0
    @Published var connectedCount = 0
    @Published var discoveryProblem: String?
    var onRetire: ((AgentKind) -> Void)?
    private var refreshes = 0

    init(_ connector: any AgentConnector) {
        self.connector = connector
        id = connector.kind.id
    }

    var kind: AgentKind { connector.kind }
    var copy: AgentConnectorCopy { connector.copy }

    var showsRemovalWarning: Bool { state == .status(.notInstalled) && connectedCount > 0 }

    var manualUninstall: [String] {
        state == .toolNotFound && connector.hasFiles ? connector.manualUninstall : []
    }

    var canUninstallWithoutTool: Bool {
        !manualUninstall.isEmpty && !connector.wasRemoved
    }

    var offersUninstall: Bool {
        if case .toolTooOld = state { return connector.hasFiles }
        return canUninstallWithoutTool
    }

    var manualUninstallLead: String? {
        guard !manualUninstall.isEmpty else { return nil }
        return canUninstallWithoutTool ? copy.manualUninstallLead : copy.manualUninstallAfterDisconnect
    }

    var isInstalled: Bool {
        switch state {
        case .status(.ready), .status(.outdated), .status(.disabled): true
        default: false
        }
    }

    func refresh() async {
        guard connector.isBundled else {
            state = .unavailable
            return
        }
        guard let tool = connector.locateTool() else {
            state = .toolNotFound
            return
        }
        refreshes += 1
        let ticket = refreshes
        let found = await connector.check(tool: tool)
        guard ticket == refreshes, operation == nil else { return }
        state = found
    }

    func install() async { await perform("Installing…", reloads: true) { try await $0.install(tool: $1) } }
    func update() async { await perform("Updating…", reloads: true) { try await $0.update(tool: $1) } }

    func remove() async {
        guard operation == nil else { return }
        do {
            try connector.disable()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        onRetire?(kind)
        await perform("Uninstalling…", reloads: false) { try await $0.uninstall(tool: $1) }
    }

    private func perform(_ progress: String, reloads: Bool, _ action: @MainActor (any AgentConnector, String) async throws -> Void) async {
        guard operation == nil else { return }
        guard connector.isBundled else {
            state = .unavailable
            return
        }
        guard let tool = connector.locateTool() else {
            state = .toolNotFound
            return
        }
        operation = progress
        refreshes += 1
        var failure: String?
        do {
            try await action(connector, tool)
        } catch let error as AgentConnectorError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
        if let failure {
            let found = connector.wasRemoved ? await connector.check(tool: tool) : nil
            operation = nil
            state = found == .removalUnfinished(nil) ? .removalUnfinished(failure) : .failed(failure)
            needsReload = false
            return
        }
        operation = nil
        needsReload = reloads
        await refresh()
    }
}
