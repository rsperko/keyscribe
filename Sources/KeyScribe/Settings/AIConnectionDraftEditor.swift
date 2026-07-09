import SwiftUI
import KeyScribeKit

struct AIConnectionDraftEditor: View {
    enum Presentation {
        case onboarding
        case settings
    }

    let presentation: Presentation
    @Binding var draft: AIConnectionDraft
    let hasStoredKey: Bool
    var dependentModeNames: [String] = []
    let testState: ConnectionTestState?
    var autofocusName = false
    let onCommit: (AIConnectionDraft, String?) -> Void
    let onFetchModels: (String?) -> Void
    var onTest: (() -> Void)?
    var onConsumeFocus: () -> Void = {}
    var onDelete: (() -> Void)?

    var body: some View {
        switch presentation {
        case .onboarding:
            onboardingBody
        case .settings:
            settingsBody
        }
    }

    private var onboardingBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            serviceRows
            if draft.provider == .openaiCompatible {
                thinDivider
                endpointRows
            }
            thinDivider
            authenticationRows
            thinDivider
            modelRows
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var settingsBody: some View {
        Form {
            Section("Service") {
                serviceRows
                usedByRow
            }
            if draft.provider == .openaiCompatible {
                Section("Endpoint") {
                    endpointRows
                }
            }
            Section("Authentication") {
                authenticationRows
            }
            Section("Model") {
                modelRows
            }
            if let onTest {
                Section("Connection test") {
                    HStack {
                        Button("Test Connection", action: onTest)
                            .disabled(testState == .testing || !draft.canTestInSettings(hasStoredKey: hasStoredKey))
                            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.testConnection)
                        if testState == .testing { ProgressView().controlSize(.small) }
                        Spacer()
                        testStatus
                    }
                    if case .failed(let message) = testState {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    if let reason = draft.testDisabledReasonInSettings(hasStoredKey: hasStoredKey) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("Cloud rewrite sends text to this named provider only when a mode explicitly selects it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let onDelete {
                    Button("Delete AI Service", role: .destructive, action: onDelete)
                        .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.delete)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .onAppear {
            if autofocusName { onConsumeFocus() }
            normalizeAuthForProvider()
        }
    }

    @ViewBuilder private var serviceRows: some View {
        textRow("Name", value: draft.name, prompt: "My AI service") { draft.name = $0 }
            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.name)
        if presentation == .onboarding { thinDivider }
        HStack {
            Text("Provider")
            Spacer()
            Picker("Provider", selection: providerBinding) {
                Text("OpenAI").tag(Connection.Provider.openai)
                Text("Anthropic").tag(Connection.Provider.anthropic)
                Text("Gemini").tag(Connection.Provider.gemini)
                Text("OpenAI-compatible").tag(Connection.Provider.openaiCompatible)
            }
            .labelsHidden()
            .frame(maxWidth: 230, alignment: .trailing)
            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.provider)
        }
    }

    @ViewBuilder private var usedByRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Used by")
            Spacer()
            Text(dependentModeNames.isEmpty ? "No modes yet" : dependentModeNames.joined(separator: ", "))
                .foregroundStyle(dependentModeNames.isEmpty ? .tertiary : .secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var endpointRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            textRow("Base URL", value: draft.baseURL, prompt: "http://127.0.0.1:11234/v1") { draft.baseURL = $0 }
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.baseURL)
            Text("Example: http://127.0.0.1:11234/v1")
                .font(.caption).foregroundStyle(.secondary)
            if draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requiredLabel("Base URL is required.")
            }
        }
    }

    @ViewBuilder private var authenticationRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Credential")
                Spacer()
                Picker("Credential", selection: authMethodBinding) {
                    if draft.provider == .openaiCompatible {
                        Text("No Auth").tag(Connection.AuthMethod.none)
                    }
                    Text("API Key").tag(Connection.AuthMethod.apiKey)
                    if draft.provider == .openaiCompatible || draft.authMethod == .tokenCommand {
                        Text("Command").tag(Connection.AuthMethod.tokenCommand)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: draft.provider == .openaiCompatible ? 310 : 220)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.auth)
            }
            credentialFields
        }
    }

    @ViewBuilder private var credentialFields: some View {
        switch draft.effectiveAuthMethod {
        case .none:
            Label("No Authorization header", systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary)
        case .apiKey:
            apiKeyFields
        case .tokenCommand:
            tokenCommandFields
        }
    }

    private var apiKeyFields: some View {
        VStack(alignment: .leading, spacing: presentation == .onboarding ? 4 : 8) {
            if presentation == .onboarding {
                HStack {
                    Text("API key")
                    Spacer()
                    SecureField("Paste API key", text: apiKeyBinding)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 260)
                        .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.apiKey)
                }
                if !hasStoredKey, !draft.hasUnsavedAPIKey {
                    requiredLabel("Enter an API key before connecting.")
                }
                Label("Saved when you connect", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("API key")
                    Spacer()
                    SecureField("", text: apiKeyBinding, prompt: Text("Paste API key"))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 360)
                        .onSubmit(saveKey)
                        .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.apiKey)
                }
                HStack {
                    let status = apiKeyStatus
                    Label(status.text, systemImage: status.icon)
                        .font(.caption).foregroundStyle(status.style)
                    Spacer()
                    Button("Save key", action: saveKey)
                        .disabled(!draft.hasUnsavedAPIKey)
                        .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.saveKey)
                }
                Text(draft.provider == .openaiCompatible
                     ? "Use No Auth if this endpoint accepts unauthenticated requests."
                     : "Hosted providers require a saved key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tokenCommandFields: some View {
        VStack(alignment: .leading, spacing: presentation == .onboarding ? 4 : 6) {
            textRow(
                "Command",
                value: draft.tokenCommand,
                prompt: "Command that prints a token"
            ) { value in
                draft.authMethod = .tokenCommand
                draft.tokenCommand = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.tokenCommand)
            if draft.tokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requiredLabel(
                    presentation == .onboarding
                    ? "Enter the command that prints a fresh token or key."
                    : "Enter the command that prints a fresh bearer token.")
            }
            Text(presentation == .onboarding
                 ? "stdout: raw token or JSON token fields."
                 : "Runs before requests. stdout can be a raw token or JSON containing access_token, token, id_token, or status.token.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelRows: some View {
        VStack(alignment: .leading, spacing: presentation == .onboarding ? 4 : 6) {
            textRow("Model ID", value: draft.model, prompt: "Choose or type a model ID") { draft.model = $0 }
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.model)
            if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requiredLabel("Model ID is required.")
            }
            HStack {
                Button(draft.isFetchingModels ? "Fetching Models" : "Fetch Models") {
                    onFetchModels(draft.requestAPIKey)
                }
                .disabled(fetchModelsDisabled)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.fetchModels)
                if draft.isFetchingModels { ProgressView().controlSize(.small) }
                Spacer()
                if presentation == .onboarding, !draft.availableModels.isEmpty {
                    Text("\(draft.availableModels.count) found")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu("Choose") {
                        ForEach(draft.availableModels, id: \.self) { id in
                            Button(id) {
                                draft.model = id
                                commit(nil)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                } else {
                    modelDiscoveryStatus
                }
            }
            if !draft.availableModels.isEmpty {
                if presentation == .settings {
                    Picker("Found Model", selection: foundModelBinding) {
                        Text("Manual / current").tag("")
                        ForEach(draft.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.foundModel)
                }
            }
            if let reason = modelFetchDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var modelDiscoveryStatus: some View {
        switch draft.modelDiscoveryState {
        case .loaded where presentation == .settings && !draft.availableModels.isEmpty:
            Text("\(draft.availableModels.count) found").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

    private func textRow(_ title: String, value: String, prompt: String? = nil, update: @escaping (String) -> Void) -> some View {
        Group {
            switch presentation {
            case .onboarding:
                HStack {
                    Text(title)
                    Spacer()
                    TextField("", text: Binding(
                        get: { value },
                        set: { update($0); commit(nil) }
                    ), prompt: prompt.map(Text.init))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 260)
                }
            case .settings:
                CommittedTextField(title, text: value, prompt: prompt, autofocus: title == "Name" && autofocusName) { next in
                    update(next)
                    commit(nil)
                }
            }
        }
    }

    private var thinDivider: some View {
        Divider().padding(.vertical, 6)
    }

    private var providerBinding: Binding<Connection.Provider> {
        Binding(
            get: { draft.provider },
            set: { value in
                draft.changeProvider(
                    to: value,
                    defaultOpenAICompatibleAuth: .apiKey,
                    hasStoredKey: hasStoredKey,
                    updateDefaultName: presentation == .onboarding)
                commit(nil)
            })
    }

    private var authMethodBinding: Binding<Connection.AuthMethod> {
        Binding(
            get: { draft.effectiveAuthMethod },
            set: { value in
                draft.changeAuthMethod(to: value)
                commit(nil)
            })
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { draft.apiKey },
            set: { draft.apiKey = $0 })
    }

    private var foundModelBinding: Binding<String> {
        Binding(
            get: { draft.availableModels.contains(draft.model) ? draft.model : "" },
            set: { value in
                guard !value.isEmpty else { return }
                draft.model = value
                commit(nil)
            })
    }

    private var fetchModelsDisabled: Bool {
        draft.isFetchingModels || (presentation == .onboarding
            ? !draft.canFetchModelsForSetup
            : !draft.canFetchModelsInSettings(hasStoredKey: hasStoredKey))
    }

    private var modelFetchDisabledReason: String? {
        switch presentation {
        case .onboarding:
            draft.setupModelFetchDisabledReason
        case .settings:
            draft.modelFetchDisabledReasonInSettings(hasStoredKey: hasStoredKey)
        }
    }

    private var apiKeyStatus: (text: String, icon: String, style: AnyShapeStyle) {
        if draft.hasUnsavedAPIKey {
            return ("Typed key not saved", "exclamationmark.circle.fill", AnyShapeStyle(.orange))
        }
        if hasStoredKey {
            return ("Key saved", "key.fill", AnyShapeStyle(.secondary))
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

    private func requiredLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.caption).foregroundStyle(.orange)
    }

    private func saveKey() {
        guard draft.hasUnsavedAPIKey else { return }
        draft.authMethod = .apiKey
        draft.tokenCommand = ""
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        commit(key)
        draft.apiKey = ""
    }

    private func normalizeAuthForProvider() {
        guard presentation == .settings, draft.provider != .openaiCompatible, draft.authMethod == .none else { return }
        draft.authMethod = .apiKey
        draft.tokenCommand = ""
        commit(nil)
    }

    private func commit(_ apiKey: String?) {
        guard presentation == .settings else { return }
        onCommit(draft, apiKey)
    }
}
