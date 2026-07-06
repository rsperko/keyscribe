import SwiftUI
import KeyScribeKit

struct ConnectionTester {
    var client: any LLMClient = HTTPLLMClient()

    func test(_ connection: Connection) async -> ConnectionTestState {
        do {
            let reply = try await client.complete(
                system: "You are a connection test. Reply with the single word OK.",
                user: "ping", connection: connection)
            return reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failed("The model service returned an empty response.")
                : .passed
        } catch {
            let message = (error as? ProviderTransportError)?.description ?? error.localizedDescription
            return .failed(message)
        }
    }
}

struct ConnectModesOffer {
    let connectionId: String
    let connectionName: String
    let modeIds: [String]
    let modeNames: [String]
}

@MainActor
final class AIServiceSettingsModel: ObservableObject {
    @Published private(set) var connections: [Connection] = []
    @Published var selectedID: String?
    @Published private(set) var error: String?
    @Published private(set) var testStates: [String: ConnectionTestState] = [:]
    @Published private(set) var modelSuggestionsByConnection: [String: [String]] = [:]
    @Published private(set) var modelDiscoveryStates: [String: ModelDiscoveryState] = [:]
    @Published private(set) var keyedRefs: Set<String> = []
    @Published var pendingConnectOffer: ConnectModesOffer?
    @Published var lastCreatedId: String?
    @Published private(set) var dependentNamesByConnection: [String: [String]] = [:]

    private let repository: ConfigRepository
    private var supportDir: URL { repository.supportDir }
    private var modesDir: URL { repository.modesDir }
    private var loadedSignature: String?
    private let tester: ConnectionTester
    private let listModels: (Connection, String?) async throws -> [String]
    private(set) var testTask: Task<Void, Never>?
    // Monotonic per-connection token. A post-test edit bumps it so a slow verdict landing after the reset
    // can't resurrect a stale error badge (drives the menu error dot + Modes-pane flags).
    private var testGeneration: [String: Int] = [:]

    init(
        repository: ConfigRepository,
        tester: ConnectionTester = ConnectionTester(),
        listModels: @escaping (Connection, String?) async throws -> [String] = {
            try await HTTPModelLister().listModels(for: $0, apiKey: $1)
        }
    ) {
        self.repository = repository
        self.tester = tester
        self.listModels = listModels
        reload()
    }

    func testState(for id: String) -> ConnectionTestState? { testStates[id] }
    func modelSuggestions(for id: String) -> [String] { modelSuggestionsByConnection[id] ?? [] }
    func modelDiscoveryState(for id: String) -> ModelDiscoveryState? { modelDiscoveryStates[id] }

    var failedTestIds: Set<String> {
        let present = Set(connections.map(\.id))
        return Set(testStates.compactMap { id, state -> String? in
            guard present.contains(id), case .failed = state else { return nil }
            return id
        })
    }

    func test(_ connection: Connection) {
        let id = connection.id
        guard testStates[id] != .testing else { return }
        let generation = (testGeneration[id] ?? 0) + 1
        testGeneration[id] = generation
        testStates[id] = .testing
        testTask = Task {
            let result = await tester.test(connection)
            guard testGeneration[id] == generation else { return }
            testStates[id] = result
        }
    }

    func fetchModels(for connection: Connection, apiKey: String?) async {
        let id = connection.id
        modelDiscoveryStates[id] = .loading
        do {
            let models = try await listModels(connection, apiKey)
            modelSuggestionsByConnection[id] = models
            modelDiscoveryStates[id] = .loaded
            // Re-read the live connection by id before writing: a text field's focus-loss commit can land
            // between the snapshot and here, and saving the snapshot would clobber that edit.
            if !models.isEmpty, var latest = connections.first(where: { $0.id == id }) {
                let current = latest.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !models.contains(current) {
                    latest.model = models[0]
                    save(latest)
                }
            }
        } catch {
            let message = (error as? ProviderTransportError)?.description ?? error.localizedDescription
            modelDiscoveryStates[id] = .failed(message)
        }
    }

    func reload() {
        let signature = FileFingerprint.file(supportDir.appendingPathComponent(ConnectionStore.fileName))
        if signature != loadedSignature {
            connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
            if selectedID == nil || !connections.contains(where: { $0.id == selectedID }) {
                selectedID = connections.first?.id
            }
            loadedSignature = signature
        }
        refreshKeyedRefs()
        recomputeDependents()
        error = nil
    }

    private func recomputeDependents() {
        var map: [String: [String]] = [:]
        for mode in ModeStore.loadAll(in: modesDir) {
            guard let id = mode.aiRewrite?.connection, !id.isEmpty else { continue }
            map[id, default: []].append(mode.name)
        }
        dependentNamesByConnection = map
    }

    private func refreshKeyedRefs() {
        keyedRefs = Set(connections.map(\.keyRef).filter(KeychainStore.has))
    }

    func create() {
        let wasEmpty = connections.isEmpty
        let name = "New AI Service"
        let id = ConnectionStore.newID(for: name, existing: connections.map(\.id))
        let connection = Connection(
            id: id, name: name, provider: .openai, model: Connection.Provider.openai.defaultModel,
            keyRef: "keyscribe.llm.\(id)")
        save(connection)
        selectedID = id
        lastCreatedId = id
        if wasEmpty {
            let pending = modesNeedingConnection()
            if !pending.isEmpty {
                pendingConnectOffer = ConnectModesOffer(
                    connectionId: id, connectionName: name,
                    modeIds: pending.map(\.id), modeNames: pending.map(\.name))
            }
        }
    }

    func consumeCreated() { lastCreatedId = nil }

    func dependentModeNames(of connection: Connection) -> [String] {
        dependentNamesByConnection[connection.id] ?? []
    }

    private func modesNeedingConnection() -> [Mode] {
        ModeStore.loadAll(in: modesDir).filter { mode in
            guard let rewrite = mode.aiRewrite else { return false }
            return rewrite.connection.isEmpty || !connections.contains { $0.id == rewrite.connection }
        }
    }

    func applyConnectOffer(_ offer: ConnectModesOffer) {
        var failed: [String] = []
        for var mode in ModeStore.loadAll(in: modesDir) where offer.modeIds.contains(mode.id) {
            guard var rewrite = mode.aiRewrite else { continue }
            rewrite.connection = offer.connectionId
            mode.aiRewrite = rewrite
            do { try repository.writeMode(mode) }
            catch { failed.append(mode.name) }
        }
        error = failed.isEmpty ? nil
            : "Could not connect \(failed.joined(separator: ", ")) to \(offer.connectionName)."
        recomputeDependents()
    }

    func update(_ connection: Connection, apiKey: String?) {
        testStates[connection.id] = nil
        testGeneration[connection.id, default: 0] += 1
        save(connection)
        guard let apiKey, !apiKey.isEmpty else { return }
        if KeychainStore.set(apiKey, for: connection.keyRef), KeychainStore.has(connection.keyRef) {
            keyedRefs.insert(connection.keyRef)
        } else {
            error = "Could not save the API key for \(connection.name)."
        }
    }

    func delete(_ connection: Connection) {
        do {
            let updated = try repository.deleteConnection(id: connection.id).connections
            KeychainStore.delete(connection.keyRef)
            keyedRefs.remove(connection.keyRef)
            testStates[connection.id] = nil
            // Bump so an in-flight test for the deleted connection can't land on a freshly created one
            // reusing the same id (create() re-mints the freed id).
            testGeneration[connection.id, default: 0] += 1
            modelDiscoveryStates[connection.id] = nil
            modelSuggestionsByConnection[connection.id] = nil
            connections = updated
            selectedID = updated.first?.id
            error = nil
        } catch {
            self.error = "Could not delete \(connection.name): \(error.localizedDescription)"
        }
    }

    var selected: Connection? { connections.first { $0.id == selectedID } }

    func hasKey(_ connection: Connection) -> Bool { keyedRefs.contains(connection.keyRef) }

    private func save(_ connection: Connection) {
        do {
            connections = try repository.upsertConnection(connection).connections
            error = nil
        } catch {
            self.error = "Could not save \(connection.name): \(error.localizedDescription)"
        }
    }
}

struct AIServiceSettingsView: View {
    @ObservedObject var model: AIServiceSettingsModel
    @State private var pendingDelete: Connection?

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            paneBody
        }
    }

    private var paneBody: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.connections) { connection in
                    let status = rowStatus(connection)
                    let usage = model.dependentModeNames(of: connection).count
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(connection.name)
                            Text("\(providerLabel(connection.provider)) · \(connection.model)")
                                .font(.caption).foregroundStyle(.secondary)
                            Label(status.text, systemImage: status.icon)
                                .font(.caption2)
                                .foregroundStyle(status.style)
                        }
                        Spacer()
                        Text(usage == 0 ? "Unused" : "\(usage) mode\(usage == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(usage == 0 ? .tertiary : .secondary)
                    }
                    .tag(connection.id)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Add AI Service", systemImage: "plus", action: model.create)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: 240)

            Divider()

            Group {
                if let connection = model.selected {
                    AIServiceEditor(
                        connection: connection, hasKey: model.hasKey(connection),
                        dependentModeNames: model.dependentModeNames(of: connection),
                        testState: model.testState(for: connection.id),
                        modelSuggestions: model.modelSuggestions(for: connection.id),
                        modelDiscoveryState: model.modelDiscoveryState(for: connection.id),
                        autofocusName: model.lastCreatedId == connection.id,
                        onUpdate: model.update,
                        onFetchModels: { connection, apiKey in
                            Task { await model.fetchModels(for: connection, apiKey: apiKey) }
                        },
                        onTest: { if let connection = model.selected { model.test(connection) } },
                        onConsumeFocus: model.consumeCreated,
                        onDelete: { pendingDelete = connection })
                        .id(connection.id)
                } else {
                    ContentUnavailableView(
                        "No AI services", systemImage: "wand.and.stars",
                        description: Text("Add a connection to your own AI provider to use cloud rewrite in a mode."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .confirmationDialog("Delete this AI service?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let connection = pendingDelete { model.delete(connection) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let connection = pendingDelete {
                Text(deleteMessage(for: connection))
            }
        }
        .confirmationDialog(
            "Use this service for AI rewrite?",
            isPresented: Binding(
                get: { model.pendingConnectOffer != nil },
                set: { if !$0 { model.pendingConnectOffer = nil } }),
            titleVisibility: .visible
        ) {
            if let offer = model.pendingConnectOffer {
                Button("Connect \(offer.modeIds.count) Mode\(offer.modeIds.count == 1 ? "" : "s")") {
                    model.applyConnectOffer(offer)
                    model.pendingConnectOffer = nil
                }
                Button("Not Now", role: .cancel) { model.pendingConnectOffer = nil }
            }
        } message: {
            if let offer = model.pendingConnectOffer {
                Text("\(offer.modeNames.joined(separator: ", ")) have an AI rewrite but no service yet. Point them at \(offer.connectionName)? You can change any of them later.")
            }
        }
    }

    private func deleteMessage(for connection: Connection) -> String {
        let base = "Its connection settings and API key will be removed. This cannot be undone."
        let dependents = model.dependentModeNames(of: connection)
        guard !dependents.isEmpty else { return base }
        let list = dependents.joined(separator: ", ")
        let lead = dependents.count == 1
            ? "The \(list) mode uses this service and will stop rewriting until you point it at another service."
            : "\(dependents.count) modes use this service (\(list)) and will stop rewriting until you point them at another service."
        return "\(lead) \(base)"
    }

    private func rowStatus(_ connection: Connection) -> (text: String, icon: String, style: AnyShapeStyle) {
        if case .failed = model.testState(for: connection.id) {
            return ("Connection test failed", "exclamationmark.triangle.fill", AnyShapeStyle(.red))
        }
        switch connection.configIssue {
        case .missingModel:
            return ("No model set", "exclamationmark.triangle.fill", AnyShapeStyle(.orange))
        case .missingBaseURL:
            return ("Needs a base URL", "exclamationmark.triangle.fill", AnyShapeStyle(.orange))
        case .missingTokenCommand:
            return ("Needs token command", "exclamationmark.triangle.fill", AnyShapeStyle(.orange))
        case nil:
            break
        }
        switch model.testState(for: connection.id) {
        case .passed:
            return ("Connection works", "checkmark.circle.fill", AnyShapeStyle(.green))
        case .testing:
            return ("Testing…", "ellipsis.circle", AnyShapeStyle(.secondary))
        default:
            if connection.provider == .openaiCompatible, connection.authMethod == .none {
                return ("No auth", "globe", AnyShapeStyle(.secondary))
            }
            if connection.authMethod == .tokenCommand {
                return ("Token command", "terminal", AnyShapeStyle(.secondary))
            }
            return model.hasKey(connection)
                ? ("Key stored", "key.fill", AnyShapeStyle(.secondary))
                : ("No key set", "key", AnyShapeStyle(.secondary))
        }
    }
}

private struct AIServiceEditor: View {
    let connection: Connection
    let hasKey: Bool
    var dependentModeNames: [String] = []
    let testState: ConnectionTestState?
    let modelSuggestions: [String]
    let modelDiscoveryState: ModelDiscoveryState?
    var autofocusName = false
    let onUpdate: (Connection, String?) -> Void
    let onFetchModels: (Connection, String?) -> Void
    let onTest: () -> Void
    var onConsumeFocus: () -> Void = {}
    let onDelete: () -> Void
    @State private var draft: AIConnectionDraft

    init(
        connection: Connection,
        hasKey: Bool,
        dependentModeNames: [String] = [],
        testState: ConnectionTestState?,
        modelSuggestions: [String],
        modelDiscoveryState: ModelDiscoveryState?,
        autofocusName: Bool = false,
        onUpdate: @escaping (Connection, String?) -> Void,
        onFetchModels: @escaping (Connection, String?) -> Void,
        onTest: @escaping () -> Void,
        onConsumeFocus: @escaping () -> Void = {},
        onDelete: @escaping () -> Void
    ) {
        self.connection = connection
        self.hasKey = hasKey
        self.dependentModeNames = dependentModeNames
        self.testState = testState
        self.modelSuggestions = modelSuggestions
        self.modelDiscoveryState = modelDiscoveryState
        self.autofocusName = autofocusName
        self.onUpdate = onUpdate
        self.onFetchModels = onFetchModels
        self.onTest = onTest
        self.onConsumeFocus = onConsumeFocus
        self.onDelete = onDelete
        _draft = State(initialValue: Self.draft(
            from: connection,
            apiKey: "",
            modelSuggestions: modelSuggestions,
            modelDiscoveryState: modelDiscoveryState))
    }

    var body: some View {
        AIConnectionDraftEditor(
            presentation: .settings,
            draft: $draft,
            hasStoredKey: hasKey,
            dependentModeNames: dependentModeNames,
            testState: testState,
            autofocusName: autofocusName,
            onCommit: commit,
            onFetchModels: { fetchModels(apiKey: $0) },
            onTest: onTest,
            onConsumeFocus: onConsumeFocus,
            onDelete: onDelete)
            .onChange(of: connection) { _, connection in refreshDraft(from: connection) }
            .onChange(of: modelSuggestions) { _, _ in refreshDraft(from: connection) }
            .onChange(of: modelDiscoveryState) { _, _ in refreshDraft(from: connection) }
    }

    private static func draft(
        from connection: Connection,
        apiKey: String,
        modelSuggestions: [String],
        modelDiscoveryState: ModelDiscoveryState?
    ) -> AIConnectionDraft {
        AIConnectionDraft(
            connection: connection,
            apiKey: apiKey,
            availableModels: modelSuggestions,
            modelDiscoveryState: modelDiscoveryState)
    }

    private func refreshDraft(from connection: Connection) {
        draft = Self.draft(
            from: connection,
            apiKey: draft.apiKey,
            modelSuggestions: modelSuggestions,
            modelDiscoveryState: modelDiscoveryState)
    }

    private func commit(_ draft: AIConnectionDraft, apiKey: String?) {
        var updated = draft.connection(id: connection.id, keyRef: connection.keyRef)
        updated.params = connection.params
        onUpdate(updated, apiKey)
    }

    private func fetchModels(apiKey: String?) {
        var updated = draft.connection(id: connection.id, keyRef: connection.keyRef)
        updated.params = connection.params
        onFetchModels(updated, apiKey)
    }
}
