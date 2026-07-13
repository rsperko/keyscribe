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
    // Monotonic per-connection token. A post-test edit bumps it so a slow verdict landing after the reset
    // can't resurrect a stale error badge (drives the menu error dot + Modes-pane flags).
    private var testGeneration: [String: Int] = [:]
    private var pendingOfferConnectionId: String?

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
            if case .passed = result, pendingOfferConnectionId == id,
               let current = connections.first(where: { $0.id == id }), current.configIssue == nil {
                let pending = modesNeedingConnection()
                if !pending.isEmpty {
                    pendingConnectOffer = ConnectModesOffer(
                        connectionId: id, connectionName: current.name,
                        modeIds: pending.map(\.id), modeNames: pending.map(\.name))
                }
                pendingOfferConnectionId = nil
            }
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

    // Acquire a Catalog starter: persist a new connection seeded from the preset immediately and select it, so
    // the detail becomes its live editor (option-1-rollout.md). Nothing is tested here — the connection lands
    // in an honest "No key set" / config-issue state and is not usable until the user finishes it in the editor
    // and Tests it. The API key is entered there and stored in Keychain, never here.
    func addService(preset: ConnectionPreset) {
        let existing = connections
        let id = ConnectionStore.newID(for: preset.name, existing: existing.map(\.id))
        var connection = Connection(
            id: id,
            name: uniqueName(preset.name, existing: existing),
            provider: preset.provider,
            model: preset.defaultModel,
            keyRef: "keyscribe.llm.\(id)",
            authMethod: .apiKey)
        if preset.provider == .openaiCompatible {
            connection.baseUrl = preset.baseURL
        }
        let wasEmpty = existing.isEmpty
        save(connection)
        selectedID = id
        testStates[id] = nil
        if wasEmpty { pendingOfferConnectionId = id }
    }

    private func uniqueName(_ base: String, existing: [Connection]) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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
        if pendingConnectOffer?.connectionId == connection.id { pendingConnectOffer = nil }
        testStates[connection.id] = nil
        testGeneration[connection.id, default: 0] += 1
        save(connection)
        guard let apiKey, !apiKey.isEmpty else { return }
        if saveAPIKey(connection.keyRef, apiKey) {
            keyedRefs.insert(connection.keyRef)
        } else {
            error = "Could not save the API key for \(connection.name)."
        }
    }

    // Rotating a keyRef appends a fresh UUID so the old Keychain item is orphaned rather than reused. Strip
    // any UUID a prior rotation already appended first, so repeated boundary crossings can't grow the ref
    // unboundedly (base.uuid1.uuid2…) — it stays base + exactly one UUID.
    private func rotationBase(_ keyRef: String) -> String {
        let parts = keyRef.split(separator: ".", omittingEmptySubsequences: false)
        if let last = parts.last, UUID(uuidString: String(last)) != nil {
            return parts.dropLast().joined(separator: ".")
        }
        return keyRef
    }

    func updateAcrossCredentialBoundary(_ connection: Connection) {
        deleteAPIKey(connection.keyRef)
        keyedRefs.remove(connection.keyRef)
        modelDiscoveryStates[connection.id] = nil
        modelSuggestionsByConnection[connection.id] = nil
        var connection = connection
        connection.keyRef = "\(rotationBase(connection.keyRef)).\(UUID().uuidString)"
        update(connection, apiKey: nil)
    }

    func delete(_ connection: Connection) {
        do {
            let updated = try repository.deleteConnection(id: connection.id).connections
            deleteAPIKey(connection.keyRef)
            keyedRefs.remove(connection.keyRef)
            testStates[connection.id] = nil
            // Bump so an in-flight test for the deleted connection can't land on a freshly created one
            // reusing the same id (create() re-mints the freed id).
            testGeneration[connection.id, default: 0] += 1
            modelDiscoveryStates[connection.id] = nil
            modelSuggestionsByConnection[connection.id] = nil
            if pendingOfferConnectionId == connection.id { pendingOfferConnectionId = nil }
            if pendingConnectOffer?.connectionId == connection.id { pendingConnectOffer = nil }
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
    @State private var showingAddService = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                IssueText(error)
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
                Section {
                    ForEach(model.connections) { connection in
                        let status = rowStatus(connection)
                        PaneListRow(
                            title: connection.name,
                            subtitle: "\(serviceLabel(connection)) · \(connection.model)",
                            status: PaneRowStatus(text: status.text, systemImage: status.icon, style: status.style),
                            trailing: {
                                if model.connections.count > 1, model.dependentModeNames(of: connection).isEmpty {
                                    Text("Unused").font(.caption2).foregroundStyle(.tertiary)
                                }
                            })
                            .tag(connection.id)
                            .accessibilityIdentifier(AccessibilityID.Settings.AI.row(connection.id))
                    }
                } header: {
                    PaneListSectionHeader("Your Services")
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.AI.list)
            .paneListActionBar {
                Button("Add AI Service…", systemImage: "plus") { showingAddService = true }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.add)
            }
            .frame(width: PaneMetrics.listWidth)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .sheet(isPresented: $showingAddService) {
            AddAIServiceChooser(
                onAdd: { preset in
                    model.addService(preset: preset)
                    showingAddService = false
                },
                onCancel: { showingAddService = false })
        }
        .confirmationDialog("Delete this AI service?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let connection = pendingDelete { model.delete(connection) }
                pendingDelete = nil
            }
            .accessibilityIdentifier(AccessibilityID.Settings.AI.deleteConfirmConfirm)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
                .accessibilityIdentifier(AccessibilityID.Settings.AI.deleteConfirmCancel)
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
                .accessibilityIdentifier(AccessibilityID.Settings.AI.connectOfferConnect)
                Button("Not Now", role: .cancel) { model.pendingConnectOffer = nil }
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.connectOfferDismiss)
            }
        } message: {
            if let offer = model.pendingConnectOffer {
                Text("\(offer.modeNames.joined(separator: ", ")) have an AI rewrite but no service yet. Point them at \(offer.connectionName)? You can change any of them later.")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let connection = model.selected {
            AIServiceEditor(
                connection: connection, hasKey: model.hasKey(connection),
                dependentModeNames: model.dependentModeNames(of: connection),
                testState: model.testState(for: connection.id),
                modelSuggestions: model.modelSuggestions(for: connection.id),
                modelDiscoveryState: model.modelDiscoveryState(for: connection.id),
                onUpdate: model.update,
                onBoundaryUpdate: model.updateAcrossCredentialBoundary,
                onFetchModels: { connection, apiKey in
                    Task { await model.fetchModels(for: connection, apiKey: apiKey) }
                },
                onTest: { if let connection = model.selected { model.test(connection) } },
                onDelete: { pendingDelete = connection })
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

private struct AddAIServiceChooser: View {
    let onAdd: (ConnectionPreset) -> Void
    let onCancel: () -> Void
    @State private var selectedPresetID = ConnectionPreset.all.first?.id

    private var selectedPreset: ConnectionPreset? {
        selectedPresetID.flatMap(ConnectionPreset.preset(id:)) ?? ConnectionPreset.all.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add AI Service").font(.title2.bold())
            Text("Choose a provider, then add its key and test the connection.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                List(selection: $selectedPresetID) {
                    Section("Providers") {
                        ForEach(ConnectionPreset.all) { preset in
                            Text(preset.pickerLabel).tag(Optional(preset.id))
                        }
                    }
                }
                .frame(width: 250)
                if let preset = selectedPreset {
                    AIServiceStarterPreview(preset: preset) { onAdd(preset) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.chooserCancel)
            }
        }
        .padding(24)
        .frame(width: 760, height: 500)
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
    let onUpdate: (Connection, String?) -> Void
    let onBoundaryUpdate: (Connection) -> Void
    let onFetchModels: (Connection, String?) -> Void
    let onTest: () -> Void
    var onConsumeFocus: () -> Void = {}
    let onDelete: () -> Void
    @State private var draft: AIConnectionDraft
    @State private var pendingBoundaryConnection: Connection?

    init(
        connection: Connection,
        hasKey: Bool,
        dependentModeNames: [String] = [],
        testState: ConnectionTestState?,
        modelSuggestions: [String],
        modelDiscoveryState: ModelDiscoveryState?,
        autofocusName: Bool = false,
        onUpdate: @escaping (Connection, String?) -> Void,
        onBoundaryUpdate: @escaping (Connection) -> Void,
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
        self.onBoundaryUpdate = onBoundaryUpdate
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
        VStack(alignment: .leading, spacing: 0) {
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
        .confirmationDialog("Change AI service?", isPresented: Binding(
            get: { pendingBoundaryConnection != nil },
            set: { if !$0 { cancelCredentialBoundary() } }), titleVisibility: .visible) {
                Button("Change Service", role: .destructive) { confirmCredentialBoundary() }
                Button("Cancel", role: .cancel) { cancelCredentialBoundary() }
            } message: {
                Text("Continuing removes the saved API key. Enter a new key before this service can be used.")
            }
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

    // Rebuilding from the just-saved connection must not re-derive the picked service from its base URL
    // (a custom endpoint at a hosted preset's URL would flip to managed and hide its fields) nor drop the
    // stash that lets a service switch-back restore the previous endpoint.
    private func refreshDraft(from connection: Connection) {
        var next = Self.draft(
            from: connection,
            apiKey: draft.apiKey,
            modelSuggestions: modelSuggestions,
            modelDiscoveryState: modelDiscoveryState)
        next.presetId = draft.presetId
        next.stashedServiceValues = draft.stashedServiceValues
        draft = next
    }

    private func commit(_ draft: AIConnectionDraft, apiKey: String?) {
        var updated = draft.connection(id: connection.id, keyRef: connection.keyRef)
        updated.params = draft.resolvedParams(for: connection)
        if hasKey, connection.crossesCredentialBoundary(to: updated) {
            pendingBoundaryConnection = updated
            return
        }
        onUpdate(updated, apiKey)
    }

    private func confirmCredentialBoundary() {
        guard let pendingBoundaryConnection else { return }
        self.pendingBoundaryConnection = nil
        onBoundaryUpdate(pendingBoundaryConnection)
    }

    // Cancel fully reverts the service flip: rebuild the draft from the unchanged connection so the picked
    // service (presetId) and its stashed values are re-derived from what is actually stored — NOT preserved
    // like the post-save refreshDraft path, which would keep the flipped presetId over reverted values and
    // strand the editor showing a managed preset's hidden fields against a custom endpoint's data.
    private func cancelCredentialBoundary() {
        pendingBoundaryConnection = nil
        draft = Self.draft(
            from: connection,
            apiKey: draft.apiKey,
            modelSuggestions: modelSuggestions,
            modelDiscoveryState: modelDiscoveryState)
    }

    private func fetchModels(apiKey: String?) {
        var updated = draft.connection(id: connection.id, keyRef: connection.keyRef)
        updated.params = draft.resolvedParams(for: connection)
        onFetchModels(updated, apiKey)
    }
}

// The Catalog detail for a provider starter: a reduced, read-only preview with one CTA, Add Service. Pressing
// it persists a seeded connection and swaps this preview for that connection's live editor
// (installed-catalog-behavior.md). No fields, no test, no destructive controls live here — the connection is
// finished and tested in the editor after it exists.
private struct AIServiceStarterPreview: View {
    let preset: ConnectionPreset
    let onAdd: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("NEW AI SERVICE")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                PaneDetailHeader(
                    systemImage: "wand.and.stars",
                    title: preset.name,
                    subtitle: subtitle)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Endpoint").foregroundStyle(.secondary)
                        Text(preset.isCustom ? "You provide the URL" : "Known — no URL to enter")
                    }
                    GridRow {
                        Text("Sign-in").foregroundStyle(.secondary)
                        Text("Your own API key")
                    }
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(preset.defaultModel.isEmpty
                            ? "You choose after connecting"
                            : "Defaults to \(preset.defaultModel) — changeable")
                    }
                }
                .font(.callout)

                Divider()

                Button("Add Service", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Preview.add(preset.id))
                Text("Adds \(preset.name) to Your Services. Paste your key and Test it there — text is sent only when a mode uses it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var subtitle: String {
        preset.isManaged
            ? "A hosted OpenAI-compatible service — connect with your key."
            : "Connect with your own \(preset.name) account."
    }
}
