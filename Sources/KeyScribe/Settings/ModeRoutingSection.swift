import AppKit
import SwiftUI
import KeyScribeKit

struct ModeRoutingSection: View {
    let mode: Mode
    let allModes: [Mode]
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    let onUpdate: (Mode) -> Void
    @State private var routingExpanded = false
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

    // First level (UX2 phase 7a): Shortcut, Spoken phrase, Use in — plain language. Advanced routing keeps
    // press style, window-title, and the raw URL regex.
    var body: some View {
        Section("When to use it") {
            ModeTriggerRow(mode: mode, onUpdate: onUpdate)

            spokenPhraseLevel
            Divider().padding(.vertical, 2)
            useInLevel

            DisclosureSection(
                isExpanded: $routingExpanded,
                hasError: trigger.conflict != nil || trigger.overlap != nil
            ) {
                DisclosureSummaryLabel(title: "More ways to trigger", summary: routingSummary)
            } content: {
                PressStyleRow(selection: trigger.pressStyle, disabled: mode.triggerKeys.isEmpty)
                TriggerConflictLabel(conflict: trigger.conflict)
                TriggerOverlapLabel(overlap: trigger.overlap)
                Text("Use Fn, a keyboard shortcut, or an extra mouse button to start this mode directly. Bound mouse buttons are used by \(Branding.appName) while it runs, so they won’t also go Back or Forward in other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Window title (regular expression)")
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                HStack {
                    TextField("Window title regex, e.g. (?i)pull request", text: $newWindowTitlePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitWindowTitleConstraint)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.windowTitle)
                    Button("Add", action: commitWindowTitleConstraint)
                        .disabled(newWindowTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.windowTitleAdd)
                }
                Text("URL (regular expression)")
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                HStack {
                    TextField("URL regex, e.g. github\\.com", text: $newURLPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitURLConstraint)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.urlPattern)
                    Button("Add", action: commitURLConstraint)
                        .disabled(newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.urlPatternAdd)
                }

                Text("Routing rules choose a mode before recording. Each is checked only when a mode uses it. URLs are local routing keys and are never sent to a rewrite provider. A spoken phrase said at the end can reroute the result after transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.disclosure)
        }
    }

    private var spokenPhraseLevel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spoken phrase").font(.subheadline.weight(.semibold))
            Text("End a dictation with a phrase to hand the result to this mode — e.g. \u{201C}…and that's the plan, as an email.\u{201D}")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(mode.triggerPhrases.enumerated()), id: \.element) { index, phrase in
                HStack {
                    Text(ModeSummary.spokenPhrase(phrase, capitalized: false)).font(.callout)
                    Spacer()
                    Button("Remove", role: .destructive) { removePhrase(phrase) }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phraseRemove(index))
                }
            }
            HStack {
                TextField("Spoken phrase, e.g. as a note", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitPhrase)
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phrase)
                Button("Add", action: commitPhrase)
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.phraseAdd)
            }
        }
    }

    private var useInLevel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use in").font(.subheadline.weight(.semibold))
            if !mode.constraints.isEmpty && mode.triggerKeys.isEmpty {
                Text("An app or website rule alone doesn’t run a mode automatically — give it the same shortcut as Plain Dictation (Fn) to take over in matching apps, or pick it from the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(mode.constraints.indices, id: \.self) { index in
                HStack {
                    constraintLabel(mode.constraints[index])
                    Spacer()
                    Button("Remove", role: .destructive) { removeConstraint(at: index) }
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.constraintRemove(index))
                }
            }
            HStack {
                Menu("Add…") {
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
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitManualBundleId)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.bundleID)
                    Button("Add", action: commitManualBundleId)
                        .disabled(manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(AccessibilityID.Mode.Editor.Routing.bundleIDAdd)
                }
            }
            if enteringDomain {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("Website domain, e.g. github.com", text: $newDomain)
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
        }
    }

    private var routingSummary: String {
        if trigger.conflict != nil { return "Shortcut conflict" }
        return "Press style, window title, URL regex"
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

    // The friendly domain-first entry: stores a host-anchored regex (host = domain or subdomain), never the
    // raw domain string, so `github.com` never substring-matches `notgithub.com` (UX2 phase 7a).
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
