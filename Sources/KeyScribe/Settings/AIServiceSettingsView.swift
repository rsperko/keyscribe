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
            return .failed(Self.failureMessage(for: error, connection: connection))
        }
    }

    static func failureMessage(for error: Error, connection: Connection) -> String {
        if case let ProviderTransportError.http(status, body) = error,
           status == 404 || status == 405,
           connection.provider == .openai || connection.provider == .openaiCompatible {
            if OpenAIAPIError.parse(body: body)?.indicatesMissingModel == true {
                return "The service could not find the model “\(connection.model)”. Check the Model ID — it may be misspelled or unavailable on this endpoint."
            }
            return "This endpoint did not respond to the Chat Completions API (POST /chat/completions). Check the Base URL — KeyScribe needs a chat model; text-completions-only models will not work."
        }
        return (error as? ProviderTransportError)?.description ?? error.localizedDescription
    }
}

struct ConnectModesOffer {
    let connectionId: String
    let connectionName: String
    let modeIds: [String]
    let modeNames: [String]
}

// The one rule deciding whether a selected service shows the summary or the full editor (UX2 phase 5b).
// A working, complete service defaults to the summary; a broken config or a service whose LAST test
// failed stays in the form until it tests clean or the app restarts (in-memory testState clears).
enum AIServiceDetailForm {
    static func showsForm(configIssue: Connection.ConfigIssue?, testState: ConnectionTestState?, isEditing: Bool) -> Bool {
        if isEditing { return true }
        if configIssue != nil { return true }
        if case .failed = testState { return true }
        return false
    }
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
    @Published private(set) var dependentNamesByConnection: [String: [String]] = [:]

    // Draft-creation flow (UX2 phase 5b): "Add AI Service" no longer inserts an empty connection; it opens a
    // draft form whose Connect button runs the shared test-then-save-with-rollback. Nothing persists until a
    // passing test, so Settings can no longer hold a half-configured, never-tested service.
    @Published var isCreatingDraft = false
    @Published var createDraft = AIConnectionDraft()
    @Published private(set) var createTesting = false
    @Published private(set) var createError: String?
    private var createPendingId: String?
    // Injected: create a disabled mode wired to a connection and route to Modes ("Create a mode with this
    // service"). Set by SettingsRootView.
    var onCreateModeWithConnection: ((String) -> Void)?

    private let repository: ConfigRepository
    private var supportDir: URL { repository.supportDir }
    private var modesDir: URL { repository.modesDir }
    private var loadedSignature: String?
    private let tester: ConnectionTester
    private let listModels: (Connection, String?) async throws -> [String]
    private let saveAPIKey: (String, String) -> Bool
    private let deleteAPIKey: (String) -> Void
    private(set) var testTask: Task<Void, Never>?
    private(set) var createTask: Task<Void, Never>?
    // Monotonic per-connection token. A post-test edit bumps it so a slow verdict landing after the reset
    // can't resurrect a stale error badge (drives the menu error dot + Modes-pane flags).
    private var testGeneration: [String: Int] = [:]

    init(
        repository: ConfigRepository,
        tester: ConnectionTester = ConnectionTester(),
        listModels: @escaping (Connection, String?) async throws -> [String] = {
            try await HTTPModelLister().listModels(for: $0, apiKey: $1)
        },
        saveAPIKey: @escaping (String, String) -> Bool = { KeychainStore.set($1, for: $0) && KeychainStore.has($0) },
        deleteAPIKey: @escaping (String) -> Void = { KeychainStore.delete($0) }
    ) {
        self.repository = repository
        self.tester = tester
        self.listModels = listModels
        self.saveAPIKey = saveAPIKey
        self.deleteAPIKey = deleteAPIKey
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
            // Re-read the live connection by id: a text field's focus-loss commit can land between the
            // snapshot and here. The fetched list describes the endpoint we queried, so if the provider or
            // base URL changed (or the connection was deleted) while the fetch was in flight, it is a stale
            // server's list — neither offer it as suggestions for the now-different endpoint nor auto-select
            // from it. Reset discovery to idle so the user re-fetches against the new endpoint.
            guard let latest = connections.first(where: { $0.id == id }),
                  latest.provider == connection.provider, latest.baseUrl == connection.baseUrl else {
                modelDiscoveryStates[id] = nil
                return
            }
            modelSuggestionsByConnection[id] = models
            modelDiscoveryStates[id] = .loaded
            // The auto-select additionally requires the model to be unchanged — a changed model is the
            // user's own deliberate pick, so models[0] must not overwrite it.
            if !models.isEmpty, latest.model == connection.model {
                var updated = latest
                let current = latest.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !models.contains(current) {
                    updated.model = models[0]
                    save(updated)
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

    // Open the draft-creation form. Nothing is written until connectDraft() sees a passing test.
    func beginCreate() {
        createTask?.cancel()
        createDraft = AIConnectionDraft()
        createDraft.model = Connection.Provider.openai.defaultModel
        createError = nil
        createPendingId = nil
        createTesting = false
        isCreatingDraft = true
    }

    // Discard the draft (nothing persisted; the connector rolls back a mid-flight abandon exactly as the
    // wizard-close path does). The in-flight connect task is cancelled so a late verdict cannot mutate config.
    func cancelCreate() {
        createTask?.cancel()
        createTesting = false
        isCreatingDraft = false
        createError = nil
    }

    var createCanConnect: Bool { createDraft.canConnectForSetup }

    func connectDraft() {
        createTask?.cancel()
        createTask = Task { [weak self] in await self?.runConnectDraft() }
    }

    private func runConnectDraft() async {
        createError = nil
        let connector = AIServiceConnector(
            repository: repository, saveAPIKey: saveAPIKey, deleteAPIKey: deleteAPIKey,
            testConnection: { await self.tester.test($0) })
        createTesting = true
        let result = await connector.connect(draft: createDraft, reusingId: createPendingId)
        createTesting = false
        createPendingId = result.allocatedId
        switch result.outcome {
        case .cancelled:
            return
        case .failed(let message):
            createError = message
        case .connected(let connection):
            let wasEmpty = connections.isEmpty
            isCreatingDraft = false
            reload()
            selectedID = connection.id
            testStates[connection.id] = .passed
            // The connect-modes offer fires after a successful create exactly as it did for the old bare
            // insert — but now only once a real, tested service exists.
            if wasEmpty {
                let pending = modesNeedingConnection()
                if !pending.isEmpty {
                    pendingConnectOffer = ConnectModesOffer(
                        connectionId: connection.id, connectionName: connection.name,
                        modeIds: pending.map(\.id), modeNames: pending.map(\.name))
                }
            }
        }
    }

    func fetchModelsForDraft() async {
        let id = createPendingId ?? "new-ai-service"
        let connection = createDraft.connection(id: id, keyRef: "keyscribe.llm.\(id)")
        createDraft.modelDiscoveryState = .loading
        do {
            let models = try await listModels(connection, createDraft.requestAPIKey)
            createDraft.applyFetchedModels(models)
        } catch {
            let message = (error as? ProviderTransportError)?.description ?? error.localizedDescription
            createDraft.modelDiscoveryState = .failed("Could not fetch models: \(message)")
        }
    }

    func createModeWithConnection(_ connectionId: String) {
        onCreateModeWithConnection?(connectionId)
    }


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
    // Per-selection edit toggle: keyed by connection id (reset by `.id(connection.id)` on the detail) so
    // switching services returns to the summary. Summary vs editor is decided by AIServiceDetailForm.showsForm.
    @State private var isEditing = false

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
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.row(connection.id))
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.AI.list)
            .safeAreaInset(edge: .bottom) {
                Button("Add AI Service", systemImage: "plus", action: model.beginCreate)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.add)
            }
            .frame(width: 240)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .onChange(of: model.selectedID) { _, _ in isEditing = false }
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

    @ViewBuilder private var detail: some View {
        if model.isCreatingDraft {
            AIServiceDraftForm(model: model)
        } else if let connection = model.selected {
            let showsForm = AIServiceDetailForm.showsForm(
                configIssue: connection.configIssue,
                testState: model.testState(for: connection.id),
                isEditing: isEditing)
            Group {
                if showsForm {
                    AIServiceEditor(
                        connection: connection, hasKey: model.hasKey(connection),
                        dependentModeNames: model.dependentModeNames(of: connection),
                        testState: model.testState(for: connection.id),
                        modelSuggestions: model.modelSuggestions(for: connection.id),
                        modelDiscoveryState: model.modelDiscoveryState(for: connection.id),
                        showsDone: isEditing,
                        onUpdate: model.update,
                        onFetchModels: { connection, apiKey in
                            Task { await model.fetchModels(for: connection, apiKey: apiKey) }
                        },
                        onTest: { if let connection = model.selected { model.test(connection) } },
                        onDone: { isEditing = false },
                        onDelete: { pendingDelete = connection })
                } else {
                    AIServiceSummaryView(
                        connection: connection,
                        status: rowStatus(connection),
                        dependentModeNames: model.dependentModeNames(of: connection),
                        testState: model.testState(for: connection.id),
                        onTest: { model.test(connection) },
                        onEdit: { isEditing = true },
                        onCreateMode: { model.createModeWithConnection(connection.id) })
                }
            }
            .id(connection.id)
        } else {
            ContentUnavailableView(
                "No AI services", systemImage: "wand.and.stars",
                description: Text("Add a connection to your own AI provider to use cloud rewrite in a mode."))
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

    private func rowStatus(_ connection: Connection) -> AIServiceStatus {
        AIServiceStatus.derive(
            connection: connection, testState: model.testState(for: connection.id),
            hasKey: model.hasKey(connection))
    }
}

// The shared status vocabulary for a connection — the list row, the summary, and the coordinator's error
// surface all derive works/testing/failed/no-key/token-command/no-auth from this one place (UX2 phase 5b),
// so no two surfaces phrase the same state differently.
struct AIServiceStatus {
    let text: String
    let icon: String
    let style: AnyShapeStyle

    static func derive(connection: Connection, testState: ConnectionTestState?, hasKey: Bool) -> AIServiceStatus {
        if case .failed = testState {
            return .init(text: "Connection test failed", icon: "exclamationmark.triangle.fill", style: AnyShapeStyle(.red))
        }
        switch connection.configIssue {
        case .missingModel:
            return .init(text: "No model set", icon: "exclamationmark.triangle.fill", style: AnyShapeStyle(.orange))
        case .missingBaseURL:
            return .init(text: "Needs a base URL", icon: "exclamationmark.triangle.fill", style: AnyShapeStyle(.orange))
        case .missingTokenCommand:
            return .init(text: "Needs token command", icon: "exclamationmark.triangle.fill", style: AnyShapeStyle(.orange))
        case nil:
            break
        }
        switch testState {
        case .passed:
            return .init(text: "Connection works", icon: "checkmark.circle.fill", style: AnyShapeStyle(.green))
        case .testing:
            return .init(text: "Testing…", icon: "ellipsis.circle", style: AnyShapeStyle(.secondary))
        default:
            if connection.provider == .openaiCompatible, connection.authMethod == .none {
                return .init(text: "No auth", icon: "globe", style: AnyShapeStyle(.secondary))
            }
            if connection.authMethod == .tokenCommand {
                return .init(text: "Token command", icon: "terminal", style: AnyShapeStyle(.secondary))
            }
            return hasKey
                ? .init(text: "Key stored", icon: "key.fill", style: AnyShapeStyle(.secondary))
                : .init(text: "No key set", icon: "key", style: AnyShapeStyle(.secondary))
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
    var showsDone = false
    let onUpdate: (Connection, String?) -> Void
    let onFetchModels: (Connection, String?) -> Void
    let onTest: () -> Void
    var onDone: () -> Void = {}
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
        showsDone: Bool = false,
        onUpdate: @escaping (Connection, String?) -> Void,
        onFetchModels: @escaping (Connection, String?) -> Void,
        onTest: @escaping () -> Void,
        onDone: @escaping () -> Void = {},
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
        self.showsDone = showsDone
        self.onUpdate = onUpdate
        self.onFetchModels = onFetchModels
        self.onTest = onTest
        self.onDone = onDone
        self.onConsumeFocus = onConsumeFocus
        self.onDelete = onDelete
        _draft = State(initialValue: Self.draft(
            from: connection,
            apiKey: "",
            modelSuggestions: modelSuggestions,
            modelDiscoveryState: modelDiscoveryState))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDone {
                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        // An incomplete config cannot be dismissed into a summary that would misrepresent it.
                        .disabled(connection.configIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.done)
                }
                .padding(.horizontal, 20).padding(.top, 12)
            }
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
        }
        .onChange(of: connection) { _, connection in refreshDraft(from: connection) }
        .onChange(of: modelSuggestions) { _, suggestions in
            guard !suggestions.isEmpty else { return }
            draft.applyFetchedModels(suggestions)
        }
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

// The default detail for a selected, working service (UX2 phase 5b): is it ready, and what uses it? — instead
// of endpoint/credential mechanics. Edit Connection reveals the full editor; Create a mode appears only when
// nothing uses the service yet.
private struct AIServiceSummaryView: View {
    let connection: Connection
    let status: AIServiceStatus
    let dependentModeNames: [String]
    let testState: ConnectionTestState?
    let onTest: () -> Void
    let onEdit: () -> Void
    let onCreateMode: () -> Void

    var body: some View {
        Form {
            Section {
                Text(connection.name).font(.title3.bold())
                Text("\(providerLabel(connection.provider)) · \(connection.model)")
                    .foregroundStyle(.secondary)
                Label(status.text, systemImage: status.icon)
                    .foregroundStyle(status.style)
                if case .testing = testState {
                    Label("Testing…", systemImage: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Used by") {
                    Text(dependentModeNames.isEmpty ? "No modes yet" : dependentModeNames.joined(separator: ", "))
                        .foregroundStyle(dependentModeNames.isEmpty ? .secondary : .primary)
                }
            }
            Section {
                Button("Test Connection", action: onTest)
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Summary.test)
                Button("Edit Connection", action: onEdit)
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Summary.edit)
                if dependentModeNames.isEmpty {
                    Button("Create a mode with this service", action: onCreateMode)
                        .accessibilityIdentifier(AccessibilityID.Settings.AI.Summary.createMode)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// The draft-creation form (UX2 phase 5b): same fields as onboarding (AIConnectionDraftEditor.settings), a
// primary Connect button that tests then saves via the shared connector, and the same error line. Cancel
// discards the draft — nothing is persisted until a passing test.
private struct AIServiceDraftForm: View {
    @ObservedObject var model: AIServiceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New AI Service").font(.headline)
                Spacer()
                Button("Cancel", action: model.cancelCreate)
                    .disabled(model.createTesting)
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Draft.cancel)
            }
            .padding(.horizontal, 20).padding(.top, 12)

            AIConnectionDraftEditor(
                presentation: .onboarding,
                draft: $model.createDraft,
                hasStoredKey: false,
                testState: model.createTesting ? .testing : nil,
                onCommit: { _, _ in },
                onFetchModels: { _ in Task { await model.fetchModelsForDraft() } })

            if let error = model.createError {
                Text(error).font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                if model.createTesting { ProgressView().controlSize(.small) }
                Button(model.createTesting ? "Testing…" : "Connect") {
                    model.connectDraft()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.createCanConnect || model.createTesting)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Draft.connect)
            }
            .padding(20)
        }
    }
}
