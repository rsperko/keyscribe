import Foundation

// A redaction-safe snapshot of an install, for pasting into a bug report. The projection from
// HistoryEntry is an allowlist: `heard`, `transformed`, `result`, `prompt`, `received`, and
// `routedPhrase` all carry user speech and none of them have a field here to land in. Tests pin that.
public struct DiagnosticsReport: Sendable {
    public struct Build: Sendable {
        public var appName: String
        public var version: String
        public var build: String
        public var revision: String
        public var bundleId: String
        public var variant: String
        public var osVersion: String

        public init(
            appName: String, version: String, build: String, revision: String,
            bundleId: String, variant: String, osVersion: String
        ) {
            self.appName = appName
            self.version = version
            self.build = build
            self.revision = revision
            self.bundleId = bundleId
            self.variant = variant
            self.osVersion = osVersion
        }
    }

    public struct PermissionState: Sendable {
        public var microphone: String
        public var accessibility: String

        public init(microphone: String, accessibility: String) {
            self.microphone = microphone
            self.accessibility = accessibility
        }
    }

    public struct Speech: Sendable {
        public var selectedEngine: String
        public var installed: [String]

        public init(selectedEngine: String, installed: [String]) {
            self.selectedEngine = selectedEngine
            self.installed = installed
        }
    }

    public struct ModeLine: Sendable {
        public var name: String
        public var id: String
        public var source: String
        public var output: String
        public var insertion: String
        public var usesLLM: Bool
        public var privacy: Bool
        public var excludeFromHistory: Bool
        public var triggers: [String]

        public init(
            name: String, id: String, source: String, output: String, insertion: String,
            usesLLM: Bool, privacy: Bool, excludeFromHistory: Bool, triggers: [String]
        ) {
            self.name = name
            self.id = id
            self.source = source
            self.output = output
            self.insertion = insertion
            self.usesLLM = usesLLM
            self.privacy = privacy
            self.excludeFromHistory = excludeFromHistory
            self.triggers = triggers
        }
    }

    public struct DictationLine: Sendable {
        public var timestamp: String
        public var mode: String
        public var engine: String?
        public var device: String?
        public var outcome: String
        public var cloudInvolved: Bool
        public var redaction: Bool
        public var connection: String?
        public var model: String?
        public var modeChoice: String?
        public var fallbackReason: String?

        public init(_ entry: HistoryEntry) {
            self.timestamp = DiagnosticsReport.isoTimestamp(entry.timestamp)
            self.mode = entry.modeName
            self.engine = entry.engine
            self.device = entry.device
            self.outcome = entry.outcome.rawValue
            self.cloudInvolved = entry.cloudInvolved
            self.redaction = entry.redaction
            self.connection = entry.connection
            self.model = entry.model
            self.modeChoice = entry.modeChoice?.rawValue
            self.fallbackReason = entry.fallbackReason
        }
    }

    public static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public var build: Build
    public var permissions: PermissionState
    public var speech: Speech
    public var historyEnabled: Bool
    public var historyRetentionDays: Int
    public var supportDir: String
    public var modes: [ModeLine]
    public var dictations: [DictationLine]
    public var modelLoadFailures: [String]
    public var configErrors: [String]
    public var enabledFeatures: [String]

    public init(
        build: Build, permissions: PermissionState, speech: Speech,
        historyEnabled: Bool, historyRetentionDays: Int, supportDir: String,
        modes: [ModeLine], dictations: [DictationLine],
        modelLoadFailures: [String], configErrors: [String], enabledFeatures: [String]
    ) {
        self.build = build
        self.permissions = permissions
        self.speech = speech
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.supportDir = supportDir
        self.modes = modes
        self.dictations = dictations
        self.modelLoadFailures = modelLoadFailures
        self.configErrors = configErrors
        self.enabledFeatures = enabledFeatures
    }

    public func render() -> String {
        var out: [String] = []
        out.append("\(build.appName) diagnostics")
        out.append("")
        out.append("Build")
        out.append("  version: \(build.version) (build \(build.build))")
        out.append("  revision: \(build.revision)")
        out.append("  bundle: \(build.bundleId)  variant: \(build.variant)")
        out.append("  macOS: \(build.osVersion)")
        out.append("  support dir: \(supportDir)")
        out.append("")
        out.append("Permissions")
        out.append("  microphone: \(permissions.microphone)")
        out.append("  accessibility: \(permissions.accessibility)")
        out.append("  Microphone access is attributed to the process that launched this binary, so a")
        out.append("  terminal run can report 'denied' while the app itself has access. Trust the app's")
        out.append("  own Settings screen over this line. Automation is per-target-app and is not probed.")
        out.append("")
        out.append("Speech")
        out.append("  selected engine: \(speech.selectedEngine)")
        out.append("  installed: \(speech.installed.isEmpty ? "none" : speech.installed.joined(separator: ", "))")
        if !enabledFeatures.isEmpty {
            out.append("  experimental features: \(enabledFeatures.joined(separator: ", "))")
        }
        out.append("")
        out.append(renderModes())
        out.append("")
        out.append(renderDictations())
        if !modelLoadFailures.isEmpty {
            out.append("")
            out.append("Model load failures (most recent last)")
            out.append(contentsOf: modelLoadFailures.map { "  \($0)" })
        }
        if !configErrors.isEmpty {
            out.append("")
            out.append("Config errors")
            out.append(contentsOf: configErrors.map { "  \($0)" })
        }
        out.append("")
        out.append(Self.privacyNote)
        return out.joined(separator: "\n") + "\n"
    }

    private func renderModes() -> String {
        var out = ["Modes (\(modes.count))"]
        if modes.isEmpty {
            out.append("  none configured")
            return out.joined(separator: "\n")
        }
        for m in modes {
            var flags: [String] = []
            if m.usesLLM { flags.append("ai") }
            if m.privacy { flags.append("privacy") }
            if m.excludeFromHistory { flags.append("no-history") }
            let trigger = m.triggers.isEmpty ? "" : "  triggers=\(m.triggers.joined(separator: "/"))"
            let flagged = flags.isEmpty ? "" : "  [\(flags.joined(separator: ","))]"
            out.append("  \(m.name) (\(m.id))")
            out.append("    source=\(m.source)  output=\(m.output)  insertion=\(m.insertion)\(flagged)\(trigger)")
        }
        return out.joined(separator: "\n")
    }

    private func renderDictations() -> String {
        var out = ["Recent dictations (\(dictations.count))"]
        if !historyEnabled {
            out.append("  History is off, so no dictations are recorded. Turn it on in")
            out.append("  Settings > History to capture evidence for a report.")
            return out.joined(separator: "\n")
        }
        out.append("  retention: \(historyRetentionDays) days")
        if dictations.isEmpty {
            out.append("  no dictations recorded")
            return out.joined(separator: "\n")
        }
        var sawCopied = false
        for d in dictations {
            if d.outcome == HistoryEntry.Outcome.copied.rawValue { sawCopied = true }
            var parts = ["outcome=\(d.outcome)", "mode=\(d.mode)"]
            if let engine = d.engine { parts.append("engine=\(engine)") }
            if let device = d.device { parts.append("mic=\(device)") }
            if let choice = d.modeChoice { parts.append("chosen-by=\(choice)") }
            if d.cloudInvolved { parts.append("cloud=yes") }
            if d.redaction { parts.append("redaction=yes") }
            if let connection = d.connection { parts.append("connection=\(connection)") }
            if let model = d.model { parts.append("model=\(model)") }
            out.append("  \(d.timestamp)  \(parts.joined(separator: "  "))")
            if let reason = d.fallbackReason {
                out.append("    fallback: \(reason)")
            }
        }
        out.append(contentsOf: Self.outcomeLegend(includeCopiedCaveat: sawCopied))
        return out.joined(separator: "\n")
    }

    static func outcomeLegend(includeCopiedCaveat: Bool) -> [String] {
        var out = [
            "",
            "  Reading outcomes:",
            "    inserted  the paste keystroke was posted and, on the default paste path, only the",
            "              clipboard write was verified. It does not prove the target accepted the text.",
            "    copied    delivery was diverted to the clipboard instead of inserted.",
            "    local_fallback  the AI rewrite fell back to local text. This value replaces",
            "              inserted/copied, so it does not say how the text was delivered.",
            "    A secure (password) field diverts delivery and is never written to history at all,",
            "    so a dictation that produced no row may have landed in one.",
        ]
        if includeCopiedCaveat {
            out.append("    Why a dictation was copied is not recorded in history; check the")
            out.append("    insertion log for the reason (appChanged/focusChanged/unknownTarget/")
            out.append("    accessibilityDenied/secureField).")
        }
        return out
    }

    static let privacyNote = """
        This report contains no transcript text, no clipboard contents, and no API keys.
        Dictation rows carry only mode, engine, microphone, outcome, and connection/model names.
        """
}
