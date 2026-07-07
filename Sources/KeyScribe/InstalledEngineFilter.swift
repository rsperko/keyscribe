import Foundation
import KeyScribeKit

enum InstalledEngineFilter {
    static func shouldRun(
        engineId: String,
        installedIds: Set<String> = ModelInstallStore.installedIds(),
        failedIds: Set<String> = ModelHealthStore.failedIds()
    ) -> Bool {
        guard let info = SpeechModelCatalog.entry(for: engineId) else { return true }
        if failedIds.contains(engineId) { return false }
        return info.systemManaged || installedIds.contains(engineId)
    }

    static func filter(
        _ engines: [any SpeechEngine],
        installedIds: Set<String> = ModelInstallStore.installedIds(),
        failedIds: Set<String> = ModelHealthStore.failedIds()
    ) -> [any SpeechEngine] {
        engines.filter { shouldRun(engineId: $0.id, installedIds: installedIds, failedIds: failedIds) }
    }
}
