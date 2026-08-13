import Foundation
import KeyScribeKit

enum DiagnosticsCollector {
    static let defaultDictationLimit = 10

    static func collect(dictationLimit: Int = defaultDictationLimit) -> DiagnosticsReport {
        let settings = loadSettings()
        let modeLoad = ModeStore.load(in: KeyScribePaths.modesDir, previous: [])

        return DiagnosticsReport(
            build: buildInfo(),
            permissions: permissionState(),
            speech: speechState(settings: settings),
            historyEnabled: settings?.history.enabled ?? true,
            historyRetentionDays: settings?.history.retentionDays ?? 0,
            supportDir: abbreviated(KeyScribePaths.supportDir),
            modes: modeLoad.modes.map(modeLine),
            dictations: dictationLines(settings: settings, limit: dictationLimit),
            modelLoadFailures: modelLoadFailures(),
            configErrors: configErrors(settings: settings, modeFailures: modeLoad.failures),
            enabledFeatures: enabledFeatures(settings: settings))
    }

    private static func loadSettings() -> Settings? {
        let file = KeyScribePaths.supportDir.appendingPathComponent(SettingsStore.fileName)
        guard let toml = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return try? SettingsStore.decode(from: toml)
    }

    private static func buildInfo() -> DiagnosticsReport.Build {
        let info = Bundle.main.infoDictionary ?? [:]
        return .init(
            appName: Branding.appName,
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            revision: info["SCMRevision"] as? String ?? "unknown",
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            variant: KeyScribePaths.variant.displayName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private static func permissionState() -> DiagnosticsReport.PermissionState {
        .init(
            microphone: describe(Permissions.microphoneStatus()),
            accessibility: describe(Permissions.accessibilityStatus(prompt: false)))
    }

    private static func describe(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "not granted"
        }
    }

    private static func speechState(settings: Settings?) -> DiagnosticsReport.Speech {
        let installed = ModelInstallStore.installedIds()
        let systemManaged = SpeechModelCatalog.all.filter(\.systemManaged).map(\.id)
        return .init(
            selectedEngine: settings?.stt.engine ?? Settings.defaults.stt.engine,
            installed: (installed.union(systemManaged)).sorted())
    }

    private static func modeLine(_ mode: Mode) -> DiagnosticsReport.ModeLine {
        .init(
            name: mode.name,
            id: mode.id,
            source: mode.source.rawValue,
            output: mode.output.rawValue,
            insertion: mode.insertion.rawValue,
            usesLLM: mode.aiRewrite != nil,
            privacy: mode.commands.privacy,
            excludeFromHistory: mode.excludeFromHistory,
            triggers: mode.triggerKeys.map(\.key))
    }

    private static func dictationLines(settings: Settings?, limit: Int) -> [DiagnosticsReport.DictationLine] {
        guard settings?.history.enabled ?? true else { return [] }
        let store = HistoryStore(supportDir: KeyScribePaths.supportDir)
        return store.entries(limit: limit).map(DiagnosticsReport.DictationLine.init)
    }

    private static func modelLoadFailures() -> [String] {
        guard let text = try? String(contentsOf: KeyScribePaths.modelLoadDiagFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(10).map { $0 }
    }

    private static func configErrors(settings: Settings?, modeFailures: [ModeStore.LoadFailure]) -> [String] {
        var errors = modeFailures.map { failure in
            let recovered = failure.usedLastKnownGood ? " (using last known good)" : ""
            return "modes/\(failure.id).toml: \(failure.message)\(recovered)"
        }
        let settingsFile = KeyScribePaths.supportDir.appendingPathComponent(SettingsStore.fileName)
        if settings == nil, FileManager.default.fileExists(atPath: settingsFile.path) {
            errors.append("\(SettingsStore.fileName): could not be read; defaults shown above")
        }
        return errors
    }

    private static func enabledFeatures(settings: Settings?) -> [String] {
        guard let settings else { return [] }
        return Feature.allCases.filter { settings.features.isEnabled($0) }.map(\.id)
    }

    private static func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}
