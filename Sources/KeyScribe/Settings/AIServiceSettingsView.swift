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

    private let supportDir: URL
    private let tester: ConnectionTester
    private let listModels: (Connection, String?) async throws -> [String]
    private(set) var testTask: Task<Void, Never>?

    init(
        supportDir: URL,
        tester: ConnectionTester = ConnectionTester(),
        listModels: @escaping (Connection, String?) async throws -> [String] = {
            try await HTTPModelLister().listModels(for: $0, apiKey: $1)
        }
    ) {
        self.supportDir = supportDir
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
        connections = ConnectionStore.loadOrDefault(supportDir: supportDir).connections
        if selectedID == nil || !connections.contains(where: { $0.id == selectedID }) {
            selectedID = connections.first?.id
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
        ModeStore.loadAll(in: KeyScribePaths.modesDir).filter { mode in
            guard let rewrite = mode.aiRewrite else { return false }
            return rewrite.connection.isEmpty || !connections.contains { $0.id == rewrite.connection }
        }
    }

    func applyConnectOffer(_ offer: ConnectModesOffer) {
        var failed: [String] = []
        for var mode in ModeStore.loadAll(in: KeyScribePaths.modesDir) where offer.modeIds.contains(mode.id) {
            guard var rewrite = mode.aiRewrite else { continue }
            rewrite.connection = offer.connectionId
            mode.aiRewrite = rewrite
            do { try ModeStore.write(mode, to: KeyScribePaths.modesDir) }
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
        var updated = connections
        updated.removeAll { $0.id == connection.id }
        do {
            try ConnectionStore.write(ConnectionSet(connections: updated), to: supportDir)
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
        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        do {
            try ConnectionStore.write(ConnectionSet(connections: updated), to: supportDir)
            connections = updated
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
        case nil:
            break
        }
        switch model.testState(for: connection.id) {
        case .passed:
            return ("Connection works", "checkmark.circle.fill", AnyShapeStyle(.green))
        case .testing:
            return ("Testing…", "ellipsis.circle", AnyShapeStyle(.secondary))
        default:
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
            Section("Connection") {
                CommittedTextField("Name", text: connection.name, autofocus: autofocusName) { value in
                    var updated = connection; updated.name = value; onUpdate(updated, nil)
                }
                Picker("Provider", selection: providerBinding) {
                    Text("OpenAI").tag(Connection.Provider.openai)
                    Text("Anthropic").tag(Connection.Provider.anthropic)
                    Text("Gemini").tag(Connection.Provider.gemini)
                    Text("OpenAI-compatible").tag(Connection.Provider.openaiCompatible)
                }
                if connection.provider == .openaiCompatible {
                    CommittedTextField("Base URL", text: connection.baseUrl ?? "") { value in
                        var updated = connection
                        updated.baseUrl = value.isEmpty ? nil : value
                        onUpdate(updated, nil)
                    }
                    Text("Required for an OpenAI-compatible endpoint, e.g. http://127.0.0.1:11234/v1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                modelField
            }
            Section("API key") {
                SecureField(hasKey ? "Replace API key" : "API key (optional for local endpoints)", text: $apiKey)
                    .onSubmit(saveKey)
                HStack {
                    Text(hasKey ? "Key stored in Keychain" : "No key stored")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Key", action: saveKey).disabled(apiKey.isEmpty)
                }
                Text("Hosted providers need an API key. Local OpenAI-compatible endpoints can be keyless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection test") {
                HStack {
                    Button("Test Connection", action: onTest)
                        .disabled(testState == .testing)
                    if testState == .testing { ProgressView().controlSize(.small) }
                    Spacer()
                    testStatus
                }
                if case .failed(let message) = testState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Text("Sends a short test message to confirm the key, model, and base URL respond.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Cloud rewrite sends text to this named provider only when a mode explicitly selects it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete AI Service", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear { if autofocusName { onConsumeFocus() } }
    }

    // Switching provider resets the model to the new provider's default, matching first-run onboarding —
    // otherwise the model field silently keeps the prior provider's id.
    private var providerBinding: Binding<Connection.Provider> {
        Binding(
            get: { connection.provider },
            set: { value in
                var updated = connection
                updated.provider = value
                updated.model = value.defaultModel
                onUpdate(updated, nil)
            })
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CommittedTextField("Model", text: connection.model) { value in
                    var updated = connection; updated.model = value; onUpdate(updated, nil)
                }
                if !modelSuggestions.isEmpty {
                    Menu {
                        ForEach(modelSuggestions, id: \.self) { model in
                            Button(model) {
                                var updated = connection
                                updated.model = model
                                onUpdate(updated, nil)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
                Button("Fetch Models") { onFetchModels(apiKey.isEmpty ? nil : apiKey) }
                    .disabled(modelDiscoveryState == .loading || !canFetchModels)
                if modelDiscoveryState == .loading { ProgressView().controlSize(.small) }
            }
            switch modelDiscoveryState {
            case .loaded where !modelSuggestions.isEmpty:
                Text("Found \(modelSuggestions.count) model\(modelSuggestions.count == 1 ? "" : "s").")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("Could not fetch models: \(message)")
                    .font(.caption).foregroundStyle(.orange)
            default:
                Text("Fetch models to choose from the provider list, or type a model id manually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canFetchModels: Bool {
        if connection.provider == .openaiCompatible {
            return !(connection.baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        onUpdate(connection, apiKey)
        apiKey = ""
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
