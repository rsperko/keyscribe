import AppKit
import SwiftUI
import KeyScribeKit

struct ModeRoutingSection: View {
    let mode: Mode
    let allModes: [Mode]
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    let onUpdate: (Mode) -> Void
    @State private var advancedMatchingExpanded = false
    @State private var enteringPhrase = false
    @State private var newPhrase = ""
    @State private var newURLPattern = ""
    @State private var newWindowTitlePattern = ""
    @State private var newDomain = ""
    @State private var manualBundleId = ""
    @State private var enteringBundleId = false
    @State private var enteringDomain = false
    @State private var runningApps: [InstalledApps.Info] = []

    private var trigger: ModeTrigger {
        ModeTrigger(mode: mode, allModes: allModes, actionShortcuts: actionShortcuts, onUpdate: onUpdate)
    }

    var body: some View {
        Section("Ways to use this mode") {
            ModeTriggerRow(mode: mode, onUpdate: onUpdate, label: "Shortcut")
            PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
            TriggerConflictLabel(conflict: trigger.conflict)
            TriggerOverlapLabel(overlap: trigger.overlap)
            if usesMouseShortcut {
                Text("While this shortcut is assigned, the mouse button won’t also go Back or Forward in other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            spokenPhraseLevel
        }

        Section("Where it works") {
            Text(ModeSummary.availabilityDescription(mode))
                .font(.caption)
                .foregroundStyle(.secondary)
            availabilityLevel
            DisclosureSection(
                isExpanded: $advancedMatchingExpanded
            ) {
                DisclosureSummaryLabel(
                    title: "More precise matching",
                    summary: "Window titles and URL patterns")
            } content: {
                Text("Window title (regular expression)")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    TextField("Window title regex, e.g. (?i)pull request", text: $newWindowTitlePattern)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitWindowTitleConstraint)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.windowTitle)
                    Button("Add", action: commitWindowTitleConstraint)
                        .disabled(windowTitleIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.windowTitleAdd)
                }
                if let windowTitleIssue { IssueText(windowTitleIssue.message) }
                Text("URL (regular expression)")
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                HStack {
                    TextField("URL regex, e.g. github\\.com", text: $newURLPattern)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitURLConstraint)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.urlPattern)
                    Button("Add", action: commitURLConstraint)
                        .disabled(urlPatternIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.urlPatternAdd)
                }
                if let urlPatternIssue { IssueText(urlPatternIssue.message) }

                Text("These patterns narrow where this mode is available. URLs are never sent to a rewrite provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.disclosure)
        }
    }

    private var usesMouseShortcut: Bool {
        guard let key = mode.triggerKeys.first?.key,
              let descriptor = try? KeyDescriptor(parsing: key)
        else { return false }
        if case .mouseButton = descriptor { return true }
        return false
    }

    private var spokenPhraseLevel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spoken phrase").font(.subheadline.weight(.semibold))
            Text("End a dictation with a phrase such as \u{201C}as \(mode.name.lowercased())\u{201D} to use this mode. The phrase is removed from the result.")
                .font(.caption).foregroundStyle(.secondary)
            if enteringPhrase {
                HStack {
                    TextField("Spoken phrase, e.g. as a note", text: $newPhrase)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitPhrase)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phrase)
                    Button("Add", action: commitPhrase)
                        .disabled(phraseIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phraseAdd)
                }
                if let phraseIssue { IssueText(phraseIssue.message) }
            } else {
                Button(mode.triggerPhrases.isEmpty ? "Add spoken phrase…" : "Add another spoken phrase…") {
                    enteringPhrase = true
                }
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phraseStart)
            }
            ForEach(Array(mode.triggerPhrases.enumerated()), id: \.element) { index, phrase in
                HStack {
                    Text("\u{201C}\(phrase)\u{201D}").font(.callout)
                    Spacer()
                    Button("Remove", role: .destructive) { removePhrase(phrase) }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phraseRemove(index))
                }
            }
        }
    }

    private var availabilityLevel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu("Add app or website…") {
                    ForEach(runningApps) { app in
                        Button(app.name) { addAppConstraint(app.bundleId) }
                            .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.addApp(app.bundleId))
                    }
                    Divider()
                    Button("Choose from Applications…") {
                        if let app = InstalledApps.chooseFromApplications() { addAppConstraint(app.bundleId) }
                    }
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.chooseFromApplications)
                    Button("Enter Bundle ID…") { enteringBundleId = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.enterBundleID)
                    Divider()
                    Button("Website…") { enteringDomain = true }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.addWebsite)
                }
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.addAppRule)
                .onAppear { if runningApps.isEmpty { runningApps = InstalledApps.running() } }
                Spacer()
            }
            if enteringBundleId {
                HStack {
                    TextField("Bundle ID, e.g. com.apple.Safari", text: $manualBundleId)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitManualBundleId)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.bundleID)
                    Button("Add", action: commitManualBundleId)
                        .disabled(bundleIDIssue != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.bundleIDAdd)
                }
                if let bundleIDIssue { IssueText(bundleIDIssue.message) }
            }
            if enteringDomain {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("Website domain, e.g. github.com", text: $newDomain)
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitDomainConstraint)
                            .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.websitePattern)
                        Button("Add", action: commitDomainConstraint)
                            .disabled(HostPattern.regex(forDomain: newDomain) == nil)
                            .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.websitePatternAdd)
                    }
                    Text("Matches that domain and its subdomains. Needs Automation access to read the browser URL.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(mode.constraints.indices, id: \.self) { index in
                HStack {
                    constraintLabel(mode.constraints[index])
                    Spacer()
                    Button("Remove", role: .destructive) { removeConstraint(at: index) }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.constraintRemove(index))
                }
            }
        }
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
        } else if let url = constraint.urlPattern, parts.count == 1 {
            HStack(spacing: 6) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                if let domain = HostPattern.domain(fromRegex: url) {
                    Text(domain).font(.callout)
                    Text("and subdomains").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(url).font(.callout)
                }
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
        if let url = constraint.urlPattern {
            if let domain = HostPattern.domain(fromRegex: url) {
                parts.append("Website: \(domain)")
            } else {
                parts.append("URL regex: \(url)")
            }
        }
        if let title = constraint.windowTitle { parts.append("Window title regex: \(title)") }
        return parts.isEmpty ? ["Empty routing rule"] : parts
    }

    private func commitPhrase() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserInputValidation.phraseIssue(phrase) == nil else { return }
        if !mode.triggerPhrases.contains(phrase) {
            var updated = mode
            updated.triggerPhrases.append(phrase)
            onUpdate(updated)
        }
        newPhrase = ""
        enteringPhrase = false
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
        guard UserInputValidation.identifierIssue(value, required: true) == nil else { return }
        addAppConstraint(value)
        manualBundleId = ""
        enteringBundleId = false
    }

    private func commitURLConstraint() {
        let value = newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserInputValidation.regexIssue(value) == nil else { return }
        var updated = mode
        updated.constraints.append(.init(bundleId: nil, urlPattern: value))
        onUpdate(updated)
        newURLPattern = ""
    }

    // Stores a host-anchored regex (host = domain or subdomain), never the raw domain string, so
    // `github.com` never substring-matches `notgithub.com`.
    private func commitDomainConstraint() {
        guard let pattern = HostPattern.regex(forDomain: newDomain) else { return }
        var updated = mode
        updated.constraints.append(.init(bundleId: nil, urlPattern: pattern))
        onUpdate(updated)
        newDomain = ""
        enteringDomain = false
    }

    private func commitWindowTitleConstraint() {
        let value = newWindowTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserInputValidation.regexIssue(value) == nil else { return }
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

    private var phraseIssue: UserInputValidation.Issue? { UserInputValidation.phraseIssue(newPhrase) }
    private var urlPatternIssue: UserInputValidation.Issue? { UserInputValidation.regexIssue(newURLPattern) }
    private var windowTitleIssue: UserInputValidation.Issue? { UserInputValidation.regexIssue(newWindowTitlePattern) }
    private var bundleIDIssue: UserInputValidation.Issue? { UserInputValidation.identifierIssue(manualBundleId, required: true) }
}
