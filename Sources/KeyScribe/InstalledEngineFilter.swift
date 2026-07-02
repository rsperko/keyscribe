import Foundation
import KeyScribeKit

enum InstalledEngineFilter {
    static func shouldRun(engineId: String, installedIds: Set<String> = ModelInstallStore.installedIds()) -> Bool {
        guard let info = SpeechModelCatalog.entry(for: engineId) else { return true }
        return info.systemManaged || installedIds.contains(engineId)
    }

    static func filter(_ engines: [any SpeechEngine], installedIds: Set<String> = ModelInstallStore.installedIds()) -> [any SpeechEngine] {
        engines.filter { shouldRun(engineId: $0.id, installedIds: installedIds) }
    }
}
