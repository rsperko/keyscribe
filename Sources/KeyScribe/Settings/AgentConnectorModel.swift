import Combine
import Foundation
import KeyScribeKit

struct AgentConnectorCopy: Sendable {
    var help: String
    var reloadHint: String
    var uninstallTitle: String
    var uninstallMessage: String
    var toolNotFoundLabel: String
    var toolNotFoundAdvice: String
    var toolNotWorkingLabel = ""
    var unavailable: String
    var disabledLabel: String
    var disabledAdvice: String
    var removalUnfinishedAdvice: String
    var listUnreadable: String
    var noReason: String
    var manualUninstallLead: String
    var manualUninstallAfterDisconnect: String
    var stillConnected: @Sendable (Int) -> String
    var toolTooOldLabel = ""
    var toolTooOldAdvice: @Sendable (String) -> String = { _ in "" }
    var setupTitle = "Connector"
    var purpose: String?
    var installNote: String?
    var undoOnUninstallLabel = ""
    var undoOnUninstallNote = ""
    var folderNoun = "configuration folder"
    var foldersHelp: String?
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
    var foundFolders: [URL] { get }
    func rediscover() async
    func name(of folder: URL) -> String?
    var toolProgram: String? { get }
    var folderVariable: String? { get }
    func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result
    func checkTool(_ tool: String) async -> ToolCheck?
    func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State
    func install(tool: String, target: ConnectorTarget) async throws
    func update(tool: String, target: ConnectorTarget) async throws
    func uninstall(tool: String, target: ConnectorTarget) async throws
    func undoesOnUninstall(in target: ConnectorTarget) -> Bool
    func uninstall(tool: String, target: ConnectorTarget, undoing: Bool) async throws
}

extension AgentConnector {
    var foundFolders: [URL] { [] }
    func rediscover() async {}
    func name(of folder: URL) -> String? { nil }
    var toolProgram: String? { nil }
    var folderVariable: String? { nil }
    func checkTool(_ tool: String) async -> ToolCheck? { nil }
    func undoesOnUninstall(in target: ConnectorTarget) -> Bool { false }
    func uninstall(tool: String, target: ConnectorTarget, undoing: Bool) async throws { try await uninstall(tool: tool, target: target) }
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
        func run(_ connector: any AgentConnector, tool: String, target: ConnectorTarget, undoing: Bool) async throws {
            switch self {
            case .install: try await connector.install(tool: tool, target: target)
            case .update: try await connector.update(tool: tool, target: target)
            case .remove: try await connector.uninstall(tool: tool, target: target, undoing: undoing)
            }
        }
    }

    let folder: URL
    @Published fileprivate(set) var isDefault: Bool
    let connector: any AgentConnector
    let registry: ConnectorSetupRegistry
    nonisolated let id: String
    @Published private(set) var state: AgentConnectorModel.State = .checking
    @Published private(set) var operation: String?
    @Published fileprivate(set) var usedBy: [String] = []
    @Published fileprivate(set) var connectedCount = 0
    @Published fileprivate(set) var lingering = 0
    @Published fileprivate(set) var olderCount = 0
    @Published private(set) var search: ToolSearch.Result?
    @Published private var pendingTool: String?
    private(set) var failedOperation: Operation?
    private let tools: ToolEnvironment
    private var undoingRemoval = false
    private let retire: (String) -> Void
    private var refreshes = 0

    init(
        folder: URL, isDefault: Bool, connector: any AgentConnector, registry: ConnectorSetupRegistry, tools: ToolEnvironment = .shared,
        retire: @escaping (String) -> Void
    ) {
        self.tools = tools
        self.folder = folder
        self.isDefault = isDefault
        self.connector = connector
        self.registry = registry
        self.retire = retire
        id = folder.path
    }

    var display: String { ConnectorFolders.display(folder) }
    var name: String? { connector.name(of: folder) }
    var copy: AgentConnectorCopy { connector.copy }
    private var agent: String { connector.kind.id }

    var target: ConnectorTarget {
        let setup = registry.setups?.setup(agent: agent, folder: folder.path)
        return ConnectorTarget(folder: folder, isDefault: isDefault, installation: setup?.installation, removing: setup?.removing ?? false)
    }

    var isEnrolled: Bool { target.installation != nil && !target.removing }

    var chosenTool: String? { registry.setups?.setup(agent: agent, folder: folder.path)?.tool ?? pendingTool }

    var choosesTool: Bool { connector.toolProgram != nil }

    var lookedIn: [ToolSearch.Place]? {
        guard toolMissing, chosenTool == nil, let searched = search?.searched, !searched.isEmpty else { return nil }
        return searched
    }

    var shellProblem: String? {
        switch tools.state {
        case .failed(let why): why
        case .read(_, _, let failure): failure
        case .notRun: nil
        }
    }

    var toolMissing: Bool {
        switch state {
        case .toolNotFound, .toolNotWorking: true
        default: false
        }
    }

    func choose(tool: URL?) async -> String? {
        let path = tool.map { $0.standardizedFileURL.path }
        if let path, !FileManager.default.isExecutableFile(atPath: path) {
            return "\(ConnectorFolders.display(URL(fileURLWithPath: path))) is not a command \(Branding.appName) can run."
        }
        if registry.setups?.setup(agent: agent, folder: folder.path) != nil {
            do {
                try registry.choose(tool: path, agent: agent, folder: folder.path)
            } catch {
                return error.localizedDescription
            }
        }
        pendingTool = path
        await refresh()
        return nil
    }

    func details(folders: [DiscoveryReport.Folder]) async -> String {
        let found = search ?? connector.findTool(in: folder, chosen: chosenTool)
        var check: ToolCheck?
        if case .toolNotWorking(let failed) = state { check = failed }
        else if let tool = found.tool?.path { check = await connector.checkTool(tool) }
        return DiscoveryReport(
            app: Branding.appName, agent: connector.kind.displayName, folder: folder.path, search: found, check: check, shell: tools.state,
            folders: folders, sightings: tools.sightings(agent: agent)
        ).text
    }

    var isInstalled: Bool {
        switch state {
        case .status(.ready), .status(.outdated), .status(.disabled), .broken, .unconfirmed: true
        default: false
        }
    }

    var showsRemovalWarning: Bool { !isEnrolled && lingering > 0 }

    var needsReload: Bool { isInstalled && (connectedCount < usedBy.count || olderCount > 0) }

    var hasError: Bool {
        switch state {
        case .unavailable, .failed, .removalUnfinished, .broken, .unconfirmed: true
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
        if case .toolNotWorking = state, isEnrolled { return true }
        return isInstalled || canUninstallWithoutTool || (isEnrolled && isUnconfirmed)
    }

    var offersReinstall: Bool { isEnrolled && state == .status(.notInstalled) }

    private var isUnconfirmed: Bool {
        switch state {
        case .status(.notInstalled), .status(.unknown), .failed: true
        default: false
        }
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
        failedOperation = nil
        state = found
        if case .toolNotWorking = found { lookAgainAfterMiss() }
    }

    private func lookAgainAfterMiss() {
        guard chosenTool == nil, connector.toolProgram != nil else { return }
        let tools = tools
        Task.detached { await tools.refresh(.miss) }
    }

    func retry() async {
        registry.reload()
        switch failedOperation {
        case .install: await install()
        case .update: await update()
        case .remove: await remove(undoing: undoingRemoval)
        case nil: await refresh()
        }
    }

    func install() async {
        guard operation == nil else { return }
        do {
            try registry.grant(agent: agent, folder: folder.path, tool: pendingTool)
        } catch {
            fail(.install, error.localizedDescription)
            return
        }
        await perform(.install)
    }

    func update() async { await perform(.update) }

    var undoesOnUninstall: Bool { !copy.undoOnUninstallLabel.isEmpty && connector.undoesOnUninstall(in: target) }

    func remove(undoing: Bool = false) async {
        guard operation == nil else { return }
        undoingRemoval = undoing
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
        let found = connector.findTool(in: folder, chosen: chosenTool)
        if search != found { search = found }
        guard let tool = found.tool?.path else {
            state = .toolNotFound
            lookAgainAfterMiss()
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
            try await kind.run(connector, tool: tool, target: target, undoing: undoingRemoval)
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
        case toolNotWorking(ToolCheck)
        case toolTooOld(String)
        case unavailable
        case status(AgentConnectorStatus)
        case removalUnfinished(String?)
        case failed(String)
        case broken(String)
        case unconfirmed(String)
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
    @Published private(set) var setups: [ConnectorSetupModel] = [] {
        didSet {
            setupChanges = Publishers.MergeMany(setups.map(\.objectWillChange))
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var setupChanges: AnyCancellable?
    @Published var discoveryProblem: String?
    var onRetire: ((String) -> Void)?
    private var discovered: [String] = []
    private var chosen: [String] = []
    private var uses: [Use] = []
    private(set) var hasRefreshed = false

    private let tools: ToolEnvironment

    init(_ connector: any AgentConnector, registry: ConnectorSetupRegistry, tools: ToolEnvironment = .shared) {
        self.connector = connector
        self.registry = registry
        self.tools = tools
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

    private var declared: String? {
        guard let variable = connector.folderVariable, let path = tools.folder(variable) else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path), connector.recognizes(folder: folder) else { return nil }
        return ConnectorFolders.canonical(folder).path
    }

    func sources(of setup: ConnectorSetupModel) -> [String] {
        let path = setup.folder.path
        var sources: [String] = []
        if setup.isDefault { sources.append("default") }
        if registry.setups?.setup(agent: kind.id, folder: path) != nil { sources.append("connector installed") }
        if connector.foundFolders.contains(where: { ConnectorFolders.canonical($0).path == path }) { sources.append("found on this Mac") }
        if discovered.contains(path) { sources.append("used by an open conversation") }
        if let variable = connector.folderVariable, declared == path { sources.append("\(variable) in your login shell") }
        if chosen.contains(path) { sources.append("added by you") }
        return sources
    }

    func details(for setup: ConnectorSetupModel) async -> String {
        await setup.details(folders: setups.map { DiscoveryReport.Folder(path: $0.folder.path, sources: sources(of: $0)) })
    }

    func canForget(_ setup: ConnectorSetupModel) -> Bool {
        chosen.contains(setup.folder.path) && !discovered.contains(setup.folder.path) && !setup.isDefault
            && registry.setups?.setup(agent: kind.id, folder: setup.folder.path) == nil && setup.operation == nil
    }

    func forget(_ setup: ConnectorSetupModel) {
        guard canForget(setup) else { return }
        chosen.removeAll { $0 == setup.folder.path }
        rebuild()
    }

    func maintain() async {
        await connector.rediscover()
        rebuild()
        for setup in setups where setup.isEnrolled {
            await setup.refresh()
            switch setup.state {
            case .status(.outdated), .broken: await setup.update()
            default: break
            }
        }
    }

    func refresh() async {
        hasRefreshed = true
        await connector.rediscover()
        rebuild()
        await withTaskGroup(of: Void.self) { group in
            for setup in setups { group.addTask { await setup.refresh() } }
        }
    }

    private func rebuild() {
        let defaultPath = ConnectorFolders.canonical(connector.defaultFolder).path
        let found = connector.foundFolders.map { ConnectorFolders.canonical($0).path }
        let known = (registry.setups ?? ConnectorSetups()).known(
            agent: kind.id, default: defaultPath, discovered: found + discovered + (declared.map { [$0] } ?? []) + chosen)
        for setup in setups where setup.isDefault != (setup.folder.path == defaultPath) { setup.isDefault = setup.folder.path == defaultPath }
        guard known != setups.map(\.folder.path) else { return applyUses() }
        var made: [ConnectorSetupModel] = []
        setups = known.map { path in
            if let existing = setup(for: path) { return existing }
            let setup = ConnectorSetupModel(
                folder: URL(fileURLWithPath: path, isDirectory: true), isDefault: path == defaultPath, connector: connector, registry: registry,
                tools: tools, retire: { [weak self] installation in self?.onRetire?(installation) })
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
