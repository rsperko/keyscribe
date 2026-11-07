import Foundation
import KeyScribeKit

struct AgentConnectorCopy {
    var help: String
    var reloadHint: String
    var uninstallTitle: String
    var uninstallMessage: String
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

struct ConnectorTarget: Equatable, Sendable {
    var folder: URL
    var isDefault: Bool
    var installation: String?
    var removing = false
}

@MainActor
protocol AgentConnector: AnyObject {
    var kind: AgentKind { get }
    var copy: AgentConnectorCopy { get }
    var isBundled: Bool { get }
    var bundledVersion: String? { get }
    var defaultFolder: URL { get }
    func hasFiles(in target: ConnectorTarget) -> Bool
    func manualUninstall(for target: ConnectorTarget) -> [String]
    func recognizes(folder: URL) -> Bool
    func locateTool() -> String?
    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State
    func install(tool: String, target: ConnectorTarget) async throws
    func update(tool: String, target: ConnectorTarget) async throws
    func uninstall(tool: String, target: ConnectorTarget) async throws
}

enum ConnectorFolders {
    static func contains(any names: [String], in folder: URL) -> Bool {
        names.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

@MainActor
final class ConnectorSetupModel: ObservableObject, Identifiable {
    enum Operation {
        case install, update, remove

        var progress: String {
            switch self {
            case .install: "Installing\u{2026}"
            case .update: "Updating\u{2026}"
            case .remove: "Uninstalling\u{2026}"
            }
        }

        @MainActor
        func run(_ connector: any AgentConnector, tool: String, target: ConnectorTarget) async throws {
            switch self {
            case .install: try await connector.install(tool: tool, target: target)
            case .update: try await connector.update(tool: tool, target: target)
            case .remove: try await connector.uninstall(tool: tool, target: target)
            }
        }
    }

    let folder: URL
    let isDefault: Bool
    let connector: any AgentConnector
    let registry: ConnectorSetupRegistry
    nonisolated let id: String
    @Published private(set) var state: AgentConnectorModel.State = .checking
    @Published private(set) var operation: String?
    @Published fileprivate(set) var usedBy: [String] = []
    @Published fileprivate(set) var connectedCount = 0
    @Published fileprivate(set) var lingering = 0
    @Published fileprivate(set) var olderCount = 0
    private(set) var failedOperation: Operation?
    private let retire: (String) -> Void
    private var refreshes = 0

    init(folder: URL, isDefault: Bool, connector: any AgentConnector, registry: ConnectorSetupRegistry, retire: @escaping (String) -> Void) {
        self.folder = folder
        self.isDefault = isDefault
        self.connector = connector
        self.registry = registry
        self.retire = retire
        id = folder.path
    }

    var display: String { ConnectorFolders.display(folder) }
    var copy: AgentConnectorCopy { connector.copy }
    private var agent: String { connector.kind.id }

    var target: ConnectorTarget {
        let setup = registry.setups?.setup(agent: agent, folder: folder.path)
        return ConnectorTarget(folder: folder, isDefault: isDefault, installation: setup?.installation, removing: setup?.removing ?? false)
    }

    var isEnrolled: Bool { target.installation != nil && !target.removing }

    var isInstalled: Bool {
        switch state {
        case .status(.ready), .status(.outdated), .status(.disabled): true
        default: false
        }
    }

    var showsRemovalWarning: Bool { !isEnrolled && lingering > 0 }

    var needsReload: Bool { isInstalled && (connectedCount < usedBy.count || olderCount > 0) }

    var hasError: Bool {
        switch state {
        case .unavailable, .failed, .removalUnfinished: true
        default: false
        }
    }

    var manualUninstall: [String] {
        guard state == .toolNotFound, connector.hasFiles(in: target) else { return [] }
        return connector.manualUninstall(for: target)
    }

    var canUninstallWithoutTool: Bool { !manualUninstall.isEmpty && !target.removing }

    var offersUninstall: Bool {
        if case .toolTooOld = state { return connector.hasFiles(in: target) }
        return isInstalled || canUninstallWithoutTool
    }

    var manualUninstallLead: String? {
        guard !manualUninstall.isEmpty else { return nil }
        return canUninstallWithoutTool ? copy.manualUninstallLead : copy.manualUninstallAfterDisconnect
    }

    func refresh() async {
        guard let tool = availableTool() else { return }
        refreshes += 1
        let ticket = refreshes
        let found = await connector.check(tool: tool, target: target)
        guard ticket == refreshes, operation == nil else { return }
        state = found
    }

    func retry() async {
        registry.reload()
        switch failedOperation {
        case .install: await install()
        case .update: await update()
        case .remove: await remove()
        case nil: await refresh()
        }
    }

    func install() async {
        guard operation == nil else { return }
        do {
            try registry.grant(agent: agent, folder: folder.path)
        } catch {
            fail(.install, error.localizedDescription)
            return
        }
        await perform(.install)
    }

    func update() async { await perform(.update) }

    func remove() async {
        guard operation == nil else { return }
        let installation = target.installation
        var unsaved: String?
        do {
            try registry.beginRemoval(agent: agent, folder: folder.path)
        } catch let error as ConnectorSetupRegistry.Unavailable {
            fail(.remove, error.reason)
            return
        } catch {
            unsaved = error.localizedDescription
        }
        if let installation { retire(installation) }
        await perform(.remove)
        guard case .status(.notInstalled) = state else { return }
        do {
            try registry.finishRemoval(agent: agent, folder: folder.path)
        } catch {
            unsaved = unsaved ?? error.localizedDescription
        }
        if let unsaved { fail(.remove, unsaved) }
    }

    private func availableTool() -> String? {
        guard connector.isBundled else {
            state = .unavailable
            return nil
        }
        guard let tool = connector.locateTool() else {
            state = .toolNotFound
            return nil
        }
        return tool
    }

    private func fail(_ failed: Operation, _ message: String) {
        failedOperation = failed
        state = .failed(message)
    }

    private func perform(_ kind: Operation) async {
        guard operation == nil, let tool = availableTool() else { return }
        operation = kind.progress
        refreshes += 1
        var failure: String?
        do {
            try await kind.run(connector, tool: tool, target: target)
        } catch let error as AgentConnectorError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
        if let failure {
            let found = target.removing ? await connector.check(tool: tool, target: target) : nil
            operation = nil
            if found == .removalUnfinished(nil) { state = .removalUnfinished(failure) } else { fail(kind, failure) }
            return
        }
        failedOperation = nil
        operation = nil
        await refresh()
    }
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

    struct Use: Equatable {
        var folder: String
        var name: String
        var connected: Bool
        var older = false
    }

    let connector: any AgentConnector
    let registry: ConnectorSetupRegistry
    nonisolated let id: String
    @Published private(set) var setups: [ConnectorSetupModel] = []
    @Published var discoveryProblem: String?
    var onRetire: ((String) -> Void)?
    private var discovered: [String] = []
    private var chosen: [String] = []
    private var uses: [Use] = []
    private var hasRefreshed = false

    init(_ connector: any AgentConnector, registry: ConnectorSetupRegistry) {
        self.connector = connector
        self.registry = registry
        id = connector.kind.id
        rebuild()
    }

    var kind: AgentKind { connector.kind }
    var copy: AgentConnectorCopy { connector.copy }

    func setup(for folder: String) -> ConnectorSetupModel? { setups.first { $0.folder.path == folder } }

    func show(discovered folders: [String], uses: [Use]) {
        let changed = folders != discovered
        discovered = folders
        self.uses = uses
        if changed { rebuild() } else { applyUses() }
    }

    @discardableResult
    func choose(folder: URL) -> ConnectorSetupModel? {
        let path = ConnectorFolders.canonical(folder).path
        if !chosen.contains(path) { chosen.append(path) }
        rebuild()
        return setup(for: path)
    }

    func maintain() async {
        rebuild()
        for setup in setups where setup.isEnrolled {
            await setup.refresh()
            if case .status(.outdated) = setup.state { await setup.update() }
        }
    }

    func refresh() async {
        hasRefreshed = true
        rebuild()
        await withTaskGroup(of: Void.self) { group in
            for setup in setups { group.addTask { await setup.refresh() } }
        }
    }

    private func rebuild() {
        let defaultPath = ConnectorFolders.canonical(connector.defaultFolder).path
        let known = (registry.setups ?? ConnectorSetups()).known(agent: kind.id, default: defaultPath, discovered: discovered + chosen)
        guard known != setups.map(\.folder.path) else { return applyUses() }
        var made: [ConnectorSetupModel] = []
        setups = known.map { path in
            if let existing = setup(for: path) { return existing }
            let setup = ConnectorSetupModel(
                folder: URL(fileURLWithPath: path, isDirectory: true), isDefault: path == defaultPath, connector: connector, registry: registry,
                retire: { [weak self] installation in self?.onRetire?(installation) })
            made.append(setup)
            return setup
        }
        applyUses()
        guard !made.isEmpty, hasRefreshed else { return }
        Task { for setup in made { await setup.refresh() } }
    }

    private func applyUses() {
        for setup in setups {
            let mine = uses.filter { $0.folder == setup.folder.path }
            let names = mine.map(\.name)
            if setup.usedBy != names { setup.usedBy = names }
            let connected = mine.filter(\.connected).count
            if setup.connectedCount != connected { setup.connectedCount = connected }
            let lingering = setup.isEnrolled ? 0 : connected
            if setup.lingering != lingering { setup.lingering = lingering }
            let older = mine.filter(\.older).count
            if setup.olderCount != older { setup.olderCount = older }
        }
    }
}
