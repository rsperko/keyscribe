import SwiftUI
import KeyScribeKit

enum ConnectionTestState: Equatable {
    case testing
    case passed
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

@MainActor
final class AIServiceSettingsModel: ObservableObject {
    @Published private(set) var connections: [Connection] = []
    @Published var selectedID: String?
    @Published private(set) var error: String?
    @Published private(set) var testStates: [String: ConnectionTestState] = [:]
    @Published private(set) var keyedRefs: Set<String> = []

    private let supportDir: URL
    private let tester: ConnectionTester
    private(set) var testTask: Task<Void, Never>?

    init(supportDir: URL, tester: ConnectionTester = ConnectionTester()) {
        self.supportDir = supportDir
        self.tester = tester
        reload()
    }

    func testState(for id: String) -> ConnectionTestState? { testStates[id] }

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
        let name = "New AI Service"
        let id = ConnectionStore.newID(for: name, existing: connections.map(\.id))
        let connection = Connection(
            id: id, name: name, provider: .openai, model: "gpt-4.1-mini",
            keyRef: "keyscribe.llm.\(id)")
        save(connection)
        selectedID = id
    }

    func update(_ connection: Connection, apiKey: String?) {
        if let apiKey, !apiKey.isEmpty {
            KeychainStore.set(apiKey, for: connection.keyRef)
            keyedRefs.insert(connection.keyRef)
        }
        testStates[connection.id] = nil
        save(connection)
    }

    func delete(_ connection: Connection) {
        var updated = connections
        updated.removeAll { $0.id == connection.id }
        do {
            try ConnectionStore.write(ConnectionSet(connections: updated), to: supportDir)
            KeychainStore.delete(connection.keyRef)
            keyedRefs.remove(connection.keyRef)
            testStates[connection.id] = nil
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
                        onUpdate: model.update, onTest: { model.test(connection) },
                        onDelete: { pendingDelete = connection })
                } else {
                    ContentUnavailableView(
                        "No AI services", systemImage: "wand.and.stars",
                        description: Text("Add a named BYOK connection to use cloud rewrite in a mode."))
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
    let onUpdate: (Connection, String?) -> Void
    let onTest: () -> Void
    let onDelete: () -> Void
    @State private var apiKey = ""
    @State private var advancedExpanded = false

    var body: some View {
        Form {
            Section("Connection") {
                CommittedTextField("Name", text: connection.name) { value in
                    var updated = connection; updated.name = value; onUpdate(updated, nil)
                }
                Picker("Provider", selection: binding(\.provider)) {
                    Text("OpenAI").tag(Connection.Provider.openai)
                    Text("Anthropic").tag(Connection.Provider.anthropic)
                    Text("Gemini").tag(Connection.Provider.gemini)
                    Text("OpenAI-compatible").tag(Connection.Provider.openaiCompatible)
                }
                CommittedTextField("Model", text: connection.model) { value in
                    var updated = connection; updated.model = value; onUpdate(updated, nil)
                }
            }
            Section("API key") {
                SecureField(hasKey ? "Replace API key" : "API key", text: $apiKey)
                    .onSubmit(saveKey)
                HStack {
                    Text(hasKey ? "Key stored in Keychain" : "No key stored")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Key", action: saveKey).disabled(apiKey.isEmpty)
                }
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
            DisclosureSection("Advanced connection settings", isExpanded: $advancedExpanded) {
                if connection.provider == .openaiCompatible {
                    CommittedTextField("Base URL", text: connection.baseUrl ?? "") { value in
                        var updated = connection
                        updated.baseUrl = value.isEmpty ? nil : value
                        onUpdate(updated, nil)
                    }
                }
                Text("API parameters are used only after the connection is configured.")
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
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Connection, T>) -> Binding<T> {
        Binding(get: { connection[keyPath: keyPath] }, set: { value in
            var updated = connection
            updated[keyPath: keyPath] = value
            onUpdate(updated, nil)
        })
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
