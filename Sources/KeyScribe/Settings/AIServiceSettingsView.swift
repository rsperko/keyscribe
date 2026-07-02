import SwiftUI
import KeyScribeKit

enum ConnectionTestState: Equatable {
    case testing
    case passed
    case failed(String)
}

enum ModelDiscoveryState: Equatable {
    case loading
    case loaded
    case failed(String)
}

// Sends one trivial round-trip through the BYOK client to confirm the key, model, and base URL
// actually answer. Transport lives in HTTPLLMClient; this only interprets the result.
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
            let message = (error as? LLMClientError)?.description ?? error.localizedDescription
            return .failed(message)
        }
    }
}

// Offered once, when the first AI service is added: the starter modes ship an AI rewrite prompt with no
// connection, so they can't rewrite until one exists. Rather than make the user open each mode, offer to
// point them all at the new service.
struct ConnectModesOffer: Identifiable {
    let id = UUID()
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

    private let repository: ConfigRepository
    private var supportDir: URL { repository.supportDir }
    private var modesDir: URL { repository.modesDir }
    private var loadedSignature: String?
    private let tester: ConnectionTester
    private let listModels: (Connection, String?) async throws -> [String]
    private(set) var testTask: Task<Void, Never>?

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

    // Connections (still present) whose last Test Connection failed. Drives the error badge and the
    // per-mode "uses a broken AI service" flag.
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
        testStates[id] = .testing
        testTask = Task {
            let result = await tester.test(connection)
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
            // Re-read the live connection by id before writing: a text field's focus-loss commit can
            // land between the snapshot and here, and saving the snapshot would clobber that edit.
            if !models.isEmpty, var latest = connections.first(where: { $0.id == id }) {
                let current = latest.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !models.contains(current) {
                    latest.model = models[0]
                    save(latest)
                }
            }
        } catch {
            let message = (error as? ModelListError)?.description ?? error.localizedDescription
            modelDiscoveryStates[id] = .failed(message)
        }
    }

    func reload() {
        // Skip re-decoding connections.toml when it has not changed since the last load, but always
        // re-probe the Keychain: a key is saved/removed in the Keychain without touching the file
        // (the TOML stores only key_ref), so keyedRefs must refresh even when the decode is skipped.
        let signature = FileFingerprint.file(supportDir.appendingPathComponent(ConnectionStore.fileName))
        if signature != loadedSignature {
            connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
            if selectedID == nil || !connections.contains(where: { $0.id == selectedID }) {
                selectedID = connections.first?.id
            }
            loadedSignature = signature
        }
        refreshKeyedRefs()
        error = nil
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
    }

    func update(_ connection: Connection, apiKey: String?) {
        testStates[connection.id] = nil
        // save() resets `error` on success, so persist the connection first, then let a key-save
        // failure have the last word on `error`.
        save(connection)
        guard let apiKey, !apiKey.isEmpty else { return }
        if KeychainStore.set(apiKey, for: connection.keyRef), KeychainStore.has(connection.keyRef) {
            keyedRefs.insert(connection.keyRef)
        } else {
            error = "Could not save the API key for \(connection.name) to the Keychain."
        }
    }

    func delete(_ connection: Connection) {
        do {
            // Read-modify-write from disk (not the pane's stale `connections`), so a connection another
            // surface added concurrently is not dropped by this delete.
            let updated = try repository.deleteConnection(id: connection.id).connections
            KeychainStore.delete(connection.keyRef)
            keyedRefs.remove(connection.keyRef)
            testStates[connection.id] = nil
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
            // Read-modify-write from disk (not the pane's stale `connections`): insert-or-replace by id so
            // a concurrent write from another surface is merged, not clobbered.
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
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.connections) { connection in
                    let status = rowStatus(connection)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(connection.name)
                        Text("\(providerLabel(connection.provider)) · \(connection.model)")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(status.text, systemImage: status.icon)
                            .font(.caption2)
                            .foregroundStyle(status.style)
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
                        testState: model.testState(for: connection.id),
                        modelSuggestions: model.modelSuggestions(for: connection.id),
                        modelDiscoveryState: model.modelDiscoveryState(for: connection.id),
                        autofocusName: model.lastCreatedId == connection.id,
                        onUpdate: model.update,
                        onFetchModels: { apiKey in
                            Task { await model.fetchModels(for: connection, apiKey: apiKey) }
                        },
                        onTest: { model.test(connection) },
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
            Text("Its connection settings and API key will be removed. This cannot be undone.")
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

    // A failed Test Connection is the only attention state — a missing key is legitimate for a
    // local/no-auth endpoint, so it reads neutral, not as an error.
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
    let testState: ConnectionTestState?
    let modelSuggestions: [String]
    let modelDiscoveryState: ModelDiscoveryState?
    var autofocusName = false
    let onUpdate: (Connection, String?) -> Void
    let onFetchModels: (String?) -> Void
    let onTest: () -> Void
    var onConsumeFocus: () -> Void = {}
    let onDelete: () -> Void
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("Service") {
                CommittedTextField("Name", text: connection.name, autofocus: autofocusName) { value in
                    var updated = connection; updated.name = value; onUpdate(updated, nil)
                }
                Picker("Provider", selection: providerBinding) {
                    Text("OpenAI").tag(Connection.Provider.openai)
                    Text("Anthropic").tag(Connection.Provider.anthropic)
                    Text("Gemini").tag(Connection.Provider.gemini)
                    Text("OpenAI-compatible").tag(Connection.Provider.openaiCompatible)
                }
            }
            if connection.provider == .openaiCompatible {
                Section("Endpoint") {
                    baseURLField
                }
            }
            Section("Authentication") {
                if connection.provider == .openaiCompatible {
                    Picker("Credential", selection: authMethodBinding) {
                        Text("No Auth").tag(Connection.AuthMethod.none)
                        Text("API Key").tag(Connection.AuthMethod.apiKey)
                        Text("Command").tag(Connection.AuthMethod.tokenCommand)
                    }
                    .pickerStyle(.segmented)
                    switch connection.authMethod {
                    case .none:
                        Label("No Authorization header", systemImage: "globe")
                            .font(.caption).foregroundStyle(.secondary)
                    case .apiKey:
                        apiKeyFields(optional: true)
                    case .tokenCommand:
                        tokenCommandField
                    }
                } else {
                    apiKeyFields(optional: false)
                }
            }
            Section("Model") {
                modelField
            }
            Section("Connection test") {
                HStack {
                    Button("Test Connection", action: onTest)
                        .disabled(testState == .testing || !canTest)
                    if testState == .testing { ProgressView().controlSize(.small) }
                    Spacer()
                    testStatus
                }
                if case .failed(let message) = testState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if let reason = testDisabledReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Cloud rewrite sends text to this named provider only when a mode explicitly selects it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete AI Service", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear {
            if autofocusName { onConsumeFocus() }
            normalizeAuthForProvider()
        }
    }

    private var providerBinding: Binding<Connection.Provider> {
        Binding(
            get: { connection.provider },
            set: { value in
                var updated = connection
                updated.provider = value
                updated.model = value.defaultModel
                if value == .openaiCompatible {
                    updated.authMethod = hasKey ? .apiKey : .none
                } else {
                    updated.authMethod = .apiKey
                    updated.tokenCommand = nil
                }
                apiKey = ""
                onUpdate(updated, nil)
            })
    }

    private var authMethodBinding: Binding<Connection.AuthMethod> {
        Binding(
            get: { connection.authMethod },
            set: { value in
                var updated = connection
                updated.authMethod = value
                if value != .tokenCommand { updated.tokenCommand = nil }
                apiKey = ""
                onUpdate(updated, nil)
            })
    }

    private var baseURLField: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommittedTextField("Base URL", text: connection.baseUrl ?? "") { value in
                var updated = connection
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.baseUrl = trimmed.isEmpty ? nil : trimmed
                onUpdate(updated, nil)
            }
            Text("Example: http://127.0.0.1:11234/v1")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func apiKeyFields(optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(hasKey ? "Enter replacement key" : optional ? "API key" : "API key required", text: $apiKey)
                .onSubmit(saveKey)
            HStack {
                let status = apiKeyStatus
                Label(status.text, systemImage: status.icon)
                    .font(.caption).foregroundStyle(status.style)
                Spacer()
                Button("Save to Keychain", action: saveKey)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(optional ? "Use No Auth if this endpoint accepts unauthenticated requests." : "Hosted providers require a saved key.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tokenCommandField: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommittedTextField(
                "Command", text: connection.tokenCommand ?? "",
                prompt: "e.g. gcloud auth print-access-token"
            ) { value in
                var updated = connection
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.authMethod = .tokenCommand
                updated.tokenCommand = trimmed.isEmpty ? nil : trimmed
                onUpdate(updated, nil)
            }
            if (connection.tokenCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Enter the command that prints a fresh bearer token.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Runs before requests. stdout can be a raw token or JSON containing access_token, token, id_token, or status.token.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommittedTextField("Model ID", text: connection.model) { value in
                var updated = connection; updated.model = value; onUpdate(updated, nil)
            }
            HStack {
                Button(modelDiscoveryState == .loading ? "Fetching Models" : "Fetch Models") { onFetchModels(nil) }
                    .disabled(modelDiscoveryState == .loading || !canFetchModels)
                if modelDiscoveryState == .loading { ProgressView().controlSize(.small) }
                Spacer()
                modelDiscoveryStatus
            }
            if !modelSuggestions.isEmpty {
                Picker("Found Model", selection: foundModelBinding) {
                    Text("Manual / current").tag("")
                    ForEach(modelSuggestions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }
            if let reason = modelFetchDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var modelDiscoveryStatus: some View {
        switch modelDiscoveryState {
        case .loaded where !modelSuggestions.isEmpty:
            Text("\(modelSuggestions.count) found").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

    private var foundModelBinding: Binding<String> {
        Binding(
            get: { modelSuggestions.contains(connection.model) ? connection.model : "" },
            set: { value in
                guard !value.isEmpty else { return }
                var updated = connection
                updated.model = value
                onUpdate(updated, nil)
            })
    }

    private var canFetchModels: Bool {
        if hasUnsavedAPIKey { return false }
        switch connection.provider {
        case .openaiCompatible:
            guard !(connection.baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            switch connection.authMethod {
            case .none:
                return true
            case .apiKey:
                return hasKey
            case .tokenCommand:
                return !(connection.tokenCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .openai, .anthropic, .gemini:
            return hasKey
        }
    }

    private var canTest: Bool {
        if hasUnsavedAPIKey || connection.configIssue != nil { return false }
        switch connection.provider {
        case .openaiCompatible:
            switch connection.authMethod {
            case .none:
                return true
            case .apiKey:
                return hasKey
            case .tokenCommand:
                return !(connection.tokenCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .openai, .anthropic, .gemini:
            return hasKey
        }
    }

    private var modelFetchDisabledReason: String? {
        guard modelDiscoveryState != .loading, !canFetchModels else { return nil }
        if hasUnsavedAPIKey { return "Save the typed key before fetching models." }
        switch connection.configIssue {
        case .missingBaseURL:
            return "Base URL is required before fetching models."
        case .missingTokenCommand:
            return "Token command is required before fetching models."
        case .missingModel, nil:
            break
        }
        if connection.provider == .openaiCompatible {
            if connection.authMethod == .apiKey && !hasKey { return "Save an API key or choose No Auth before fetching models." }
        } else if !hasKey {
            return "Save an API key before fetching models."
        }
        return nil
    }

    private var testDisabledReason: String? {
        if hasUnsavedAPIKey { return "Typed key is not saved yet." }
        switch connection.configIssue {
        case .missingModel:
            return "Model ID is required."
        case .missingBaseURL:
            return "Base URL is required."
        case .missingTokenCommand:
            return "Token command is required."
        case nil:
            break
        }
        if connection.provider == .openaiCompatible {
            if connection.authMethod == .apiKey && !hasKey { return "Save an API key or choose No Auth." }
        } else if !hasKey {
            return "Save an API key before testing."
        }
        return nil
    }

    private var hasUnsavedAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var apiKeyStatus: (text: String, icon: String, style: AnyShapeStyle) {
        if hasUnsavedAPIKey {
            return ("Typed key not saved", "exclamationmark.circle.fill", AnyShapeStyle(.orange))
        }
        if hasKey {
            return ("Saved in Keychain", "key.fill", AnyShapeStyle(.secondary))
        }
        return ("No saved key", "key", AnyShapeStyle(.secondary))
    }

    @ViewBuilder private var testStatus: some View {
        switch testState {
        case .testing:
            Text("Testing…").font(.caption).foregroundStyle(.secondary)
        case .passed:
            Label("Connection works", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed:
            Label("Could not connect", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = connection
        updated.authMethod = .apiKey
        updated.tokenCommand = nil
        onUpdate(updated, trimmed)
        apiKey = ""
    }

    private func normalizeAuthForProvider() {
        guard connection.provider != .openaiCompatible, connection.authMethod != .apiKey else { return }
        var updated = connection
        updated.authMethod = .apiKey
        updated.tokenCommand = nil
        onUpdate(updated, nil)
    }
}

private func providerLabel(_ provider: Connection.Provider) -> String {
    switch provider {
    case .openai: "OpenAI"
    case .anthropic: "Anthropic"
    case .gemini: "Gemini"
    case .openaiCompatible: "OpenAI-compatible"
    }
}
