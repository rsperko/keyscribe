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
    @State private var replacingAPIKey = false
    @State private var connectionOptionsExpanded = false

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
            if draft.selectedPreset.isCustom {
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var settingsBody: some View {
        Form {
            Section {
                PaneDetailHeader(
                    systemImage: "wand.and.stars",
                    title: draft.name,
                    subtitle: serviceLabel(draft.connection(id: "draft", keyRef: "draft")),
                    badges: { PaneBadge(connectionStatus.text, kind: connectionStatus.kind, systemImage: connectionStatus.icon) })
            }
            Section("Connection") {
                textRow("Service name", value: draft.name, prompt: "My AI service") { draft.name = $0 }
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.name)
                credentialFields
                testRows
            }
            Section("Model") {
                modelRows
            }
            Section("Used by") { usedByRow }
            Section {
                DisclosureSection(isExpanded: $connectionOptionsExpanded, hasError: connectionOptionsError) {
                    DisclosureSummaryLabel(title: "Connection options", summary: connectionOptionsSummary)
                } content: {
                    serviceTypeRow
                    if draft.selectedPreset.isCustom {
                        endpointRows
                    }
                    if draft.selectedPreset.isCustom || draft.selectedPreset.offersAuthChoice {
                        authenticationMechanismRow
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.connectionOptions)
            }
            Section {
                Text("Cloud rewrite sends text to this named provider only when a mode explicitly selects it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let onDelete {
                    HStack {
                        Spacer()
                        PaneDeleteButton(title: "Delete AI Service", action: onDelete)
                            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.delete)
                    }
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
        textRow("Service name", value: draft.name, prompt: "My AI service") { draft.name = $0 }
            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.name)
        if presentation == .onboarding { thinDivider }
        serviceTypeRow
    }

    private var serviceTypeRow: some View {
        HStack {
            Text("Service type")
            Spacer()
            Picker("Service", selection: presetBinding) {
                ForEach(ConnectionPreset.all) { preset in
                    Text(preset.pickerLabel).tag(preset.id)
                }
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
            textRow("Base URL", value: draft.baseURL, prompt: "Required") { draft.baseURL = $0 }
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
            authenticationMechanismRow
            credentialFields
        }
    }

    @ViewBuilder private var authenticationMechanismRow: some View {
        if !draft.selectedPreset.isManaged || draft.selectedPreset.offersAuthChoice {
            let segments = authSegments
            HStack {
                Text("Sign in with")
                Spacer()
                Picker("Credential", selection: authMethodBinding) {
                    ForEach(segments, id: \.self) { method in
                        Text(authMethodLabel(method)).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: segments.count > 2 ? 310 : 220)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.auth)
            }
        }
    }

    // Preset's allowed methods plus the draft's current one — a connection whose TOML carries a method the
    // preset no longer offers must stay selectable, not vanish.
    private var authSegments: [Connection.AuthMethod] {
        var methods = draft.selectedPreset.allowedAuthMethods
        let current = draft.effectiveAuthMethod
        if !methods.contains(current) { methods.append(current) }
        return methods
    }

    private func authMethodLabel(_ method: Connection.AuthMethod) -> String {
        switch method {
        case .none: "No Auth"
        case .apiKey: "API Key"
        case .tokenCommand: "Command"
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
                    requiredLabel("Add an API key to connect.")
                }
                HStack {
                    Label("Stored when you connect", systemImage: "key")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    keysLink
                }
            } else {
                if hasStoredKey && !draft.hasUnsavedAPIKey && !replacingAPIKey {
                    HStack {
                        Label("API key saved", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Replace key…") { replacingAPIKey = true }
                            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.replaceKey)
                    }
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
                        if draft.hasUnsavedAPIKey {
                            Label("Unsaved API key", systemImage: "exclamationmark.circle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Save key", action: saveKey)
                            .disabled(!draft.hasUnsavedAPIKey)
                            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.saveKey)
                    }
                }
                HStack {
                    Text(draft.selectedPreset.isCustom
                         ? "Use No Auth if this endpoint accepts unauthenticated requests."
                         : "Hosted providers require a saved key.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    keysLink
                }
            }
        }
    }

    @ViewBuilder private var keysLink: some View {
        if let url = draft.selectedPreset.keysURL {
            Link("Get an API key", destination: url)
                .font(.caption)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.getKeyLink)
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
            modelComboRow
            if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requiredLabel("Model ID is required.")
            }
            HStack {
                Button(draft.isFetchingModels ? "Finding models" : "Find models") {
                    onFetchModels(draft.requestAPIKey)
                }
                .disabled(fetchModelsDisabled)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.fetchModels)
                if draft.isFetchingModels { ProgressView().controlSize(.small) }
                Spacer()
                modelDiscoveryStatus
            }
            if let reason = modelFetchDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var modelComboRow: some View {
        let combo = ModelComboBox(
            text: $draft.model, items: draft.availableModels,
            prompt: "Choose or type a model ID", onCommit: { commit(nil) })
            .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.model)
        return Group {
            switch presentation {
            case .onboarding:
                HStack {
                    Text("Model")
                    Spacer()
                    combo.frame(maxWidth: 420)
                }
            case .settings:
                LabeledContent("Model") { combo.frame(minWidth: 360) }
            }
        }
    }

    @ViewBuilder private var modelDiscoveryStatus: some View {
        switch draft.modelDiscoveryState {
        case .loaded where !draft.availableModels.isEmpty:
            Text("\(draft.availableModels.count) found").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.foundModel)
        case .failed(let message):
            IssueText(message, severity: .advisory)
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
                CommittedTextField(title, text: value, prompt: prompt, autofocus: title == "Service name" && autofocusName) { next in
                    update(next)
                    commit(nil)
                }
            }
        }
    }

    private var thinDivider: some View {
        Divider().padding(.vertical, 6)
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { draft.selectedPreset.id },
            set: { id in
                guard let preset = ConnectionPreset.preset(id: id) else { return }
                draft.applyPreset(preset, updateDefaultName: presentation == .onboarding)
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

    @ViewBuilder private var testRows: some View {
        if let onTest {
            HStack(spacing: 10) {
                Button("Test Connection", action: onTest)
                    .disabled(testState == .testing || !draft.canTestInSettings(hasStoredKey: hasStoredKey))
                    .accessibilityIdentifier(AccessibilityID.Settings.AI.Editor.testConnection)
                if testState == .testing { ProgressView().controlSize(.small) }
                testStatus
            }
            if case .failed(let message) = testState { IssueText(message) }
            if let reason = draft.testDisabledReasonInSettings(hasStoredKey: hasStoredKey) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionOptionsSummary: String {
        draft.selectedPreset.isCustom ? "Custom endpoint and sign-in" : "Change service type"
    }

    // Base URL lives inside the collapsed "Connection options" section, so a cleared endpoint must raise
    // the section's dot and auto-expand it — otherwise the required message hides behind the header.
    private var connectionOptionsError: Bool {
        draft.selectedPreset.isCustom
            && draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var connectionStatus: (text: String, icon: String, kind: PaneBadge.Kind) {
        switch testState {
        case .passed: ("Ready", "checkmark.circle.fill", .prominent)
        case .testing: ("Testing", "ellipsis.circle", .neutral)
        case .failed: ("Needs attention", "exclamationmark.triangle.fill", .warning)
        case nil: untestedStatus
        }
    }

    // Reports sign-in shape, not "No key" — a no-auth or token-command service used to always show
    // "No key" here, contradicting its own auth row.
    private var untestedStatus: (text: String, icon: String, kind: PaneBadge.Kind) {
        switch draft.effectiveAuthMethod {
        case .none: ("No auth", "globe", .neutral)
        case .tokenCommand: ("Token command", "terminal", .neutral)
        case .apiKey: hasStoredKey ? ("Key saved", "key.fill", .neutral) : ("No key", "key", .neutral)
        }
    }

    private func requiredLabel(_ text: String) -> some View {
        IssueText(text, severity: .advisory)
    }

    private func saveKey() {
        guard draft.hasUnsavedAPIKey else { return }
        draft.authMethod = .apiKey
        draft.tokenCommand = ""
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        commit(key)
        draft.apiKey = ""
        replacingAPIKey = false
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
