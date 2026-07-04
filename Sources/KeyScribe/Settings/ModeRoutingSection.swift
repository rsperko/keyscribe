import AppKit
import SwiftUI
import KeyScribeKit

struct ModeRoutingSection: View {
    let mode: Mode
    let allModes: [Mode]
    let onUpdate: (Mode) -> Void
    @State private var routingExpanded = false
    @State private var newPhrase = ""
    @State private var newURLPattern = ""
    @State private var newWindowTitlePattern = ""
    @State private var manualBundleId = ""
    @State private var enteringBundleId = false
    @State private var runningApps: [InstalledApps.Info] = []

    private var trigger: ModeTrigger { ModeTrigger(mode: mode, allModes: allModes, onUpdate: onUpdate) }

    var body: some View {
        Section("When this mode is used") {
            ModeTriggerRow(mode: mode, onUpdate: onUpdate)
            DisclosureSection(isExpanded: $routingExpanded) {
                DisclosureSummaryLabel(title: "Advanced routing", summary: routingSummary)
            } content: {
                PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
                TriggerConflictLabel(conflict: trigger.conflict)
                Text("Use Fn, a keyboard shortcut, or an extra mouse button to start this mode directly. Bound mouse buttons are used by \(Branding.appName) while it runs, so they won’t also go Back or Forward in other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Limit by app, URL, or window title")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                if !mode.constraints.isEmpty && mode.triggerKeys.isEmpty {
                    Text("An app rule alone doesn’t run a mode automatically — give it the same shortcut as Plain Dictation (Fn) to take over in matching apps, or pick it from the menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(mode.constraints.indices, id: \.self) { index in
                    HStack {
                        constraintLabel(mode.constraints[index])
                        Spacer()
                        Button("Remove", role: .destructive) { removeConstraint(at: index) }
                    }
                }
                HStack {
                    Menu("Add app rule") {
                        ForEach(runningApps) { app in
                            Button(app.name) { addAppConstraint(app.bundleId) }
                        }
                        Divider()
                        Button("Choose from Applications…") {
                            if let app = InstalledApps.chooseFromApplications() { addAppConstraint(app.bundleId) }
                        }
                        Button("Enter Bundle ID…") { enteringBundleId = true }
                    }
                    .fixedSize()
                    .onAppear { if runningApps.isEmpty { runningApps = InstalledApps.running() } }
                    Spacer()
                }
                if enteringBundleId {
                    HStack {
                        TextField("Bundle ID, e.g. com.apple.Safari", text: $manualBundleId)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitManualBundleId)
                        Button("Add", action: commitManualBundleId)
                            .disabled(manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    TextField("URL regex, e.g. github\\.com", text: $newURLPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitURLConstraint)
                    Button("Add", action: commitURLConstraint)
                        .disabled(newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    TextField("Window title regex, e.g. (?i)pull request", text: $newWindowTitlePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitWindowTitleConstraint)
                    Button("Add", action: commitWindowTitleConstraint)
                        .disabled(newWindowTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider().padding(.vertical, 4)
                Text("Choose by spoken phrase")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    TextField("Spoken phrase, e.g. as a note", text: $newPhrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitPhrase)
                    Button("Add", action: commitPhrase)
                        .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(mode.triggerPhrases, id: \.self) { phrase in
                    HStack {
                        Text(phrase).font(.callout)
                        Spacer()
                        Button("Remove", role: .destructive) { removePhrase(phrase) }
                    }
                }

                Text("Routing rules choose a mode before recording. App rules match bundle IDs, URL and window title rules are regular expressions, and each is checked only when a mode uses it. URLs are local routing keys and are never sent to a rewrite provider. A spoken phrase said at the end can reroute the result after transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var routingSummary: String {
        if trigger.conflict != nil { return "Shortcut conflict" }
        let ruleCount = mode.constraints.count
        let phraseCount = mode.triggerPhrases.count
        if ruleCount == 0 && phraseCount == 0 { return "No app rules or spoken phrases" }
        var parts: [String] = []
        if ruleCount > 0 { parts.append("\(ruleCount) rule\(ruleCount == 1 ? "" : "s")") }
        if phraseCount > 0 { parts.append("\(phraseCount) spoken phrase\(phraseCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func constraintLabel(_ constraint: Mode.Constraint) -> some View {
        let parts = constraintParts(constraint)
        if let bundle = constraint.bundleId, parts.count == 1 {
            HStack(spacing: 6) {
                if let icon = InstalledApps.icon(forBundleId: bundle) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(InstalledApps.name(forBundleId: bundle) ?? bundle).font(.callout)
                Text(bundle).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(parts.joined(separator: " + ")).font(.callout)
        }
    }

    private func constraintParts(_ constraint: Mode.Constraint) -> [String] {
        var parts: [String] = []
        if let bundle = constraint.bundleId {
            let name = InstalledApps.name(forBundleId: bundle) ?? bundle
            parts.append("App: \(name)")
        }
        if let prefix = constraint.bundlePrefix { parts.append("App prefix: \(prefix)") }
        if let url = constraint.urlPattern { parts.append("URL regex: \(url)") }
        if let title = constraint.windowTitle { parts.append("Window title regex: \(title)") }
        return parts.isEmpty ? ["Empty routing rule"] : parts
    }

    private func commitPhrase() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        if !mode.triggerPhrases.contains(phrase) {
            var updated = mode
            updated.triggerPhrases.append(phrase)
            onUpdate(updated)
        }
        newPhrase = ""
    }

    private func removePhrase(_ phrase: String) {
        var updated = mode
        updated.triggerPhrases.removeAll { $0 == phrase }
        onUpdate(updated)
    }

    private func addAppConstraint(_ bundleId: String) {
        guard !mode.constraints.contains(where: { $0.bundleId == bundleId }) else { return }
        var updated = mode
        updated.constraints.append(.init(bundleId: bundleId))
        onUpdate(updated)
    }

    private func commitManualBundleId() {
        let value = manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        addAppConstraint(value)
        manualBundleId = ""
        enteringBundleId = false
    }

    private func commitURLConstraint() {
        let value = newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = mode
        updated.constraints.append(.init(bundleId: nil, urlPattern: value))
        onUpdate(updated)
        newURLPattern = ""
    }

    private func commitWindowTitleConstraint() {
        let value = newWindowTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = mode
        updated.constraints.append(.init(windowTitle: value))
        onUpdate(updated)
        newWindowTitlePattern = ""
    }

    private func removeConstraint(at index: Int) {
        guard mode.constraints.indices.contains(index) else { return }
        var updated = mode
        updated.constraints.remove(at: index)
        onUpdate(updated)
    }
}
