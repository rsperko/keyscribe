import Foundation
import KeyScribeKit

enum ResetTarget: String, CaseIterable {
    case onboarding, modes, config, all
}

struct ResetTool {
    static let firstRunKey = "didCompleteFirstRun"

    let supportDir: URL
    let defaults: UserDefaults
    var fileManager: FileManager = .default

    @discardableResult
    func run(_ target: ResetTarget) -> [String] {
        switch target {
        case .onboarding: return clearOnboarding()
        case .modes: return reseedModes()
        case .config: return wipeConfig()
        case .all: return wipeAll()
        }
    }

    private func clearOnboarding() -> [String] {
        defaults.removeObject(forKey: Self.firstRunKey)
        return ["Cleared onboarding flag (\(Self.firstRunKey))."]
    }

    private func reseedModes() -> [String] {
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? fileManager.removeItem(at: modesDir)
        try? fileManager.createDirectory(at: modesDir, withIntermediateDirectories: true)
        ModeStore.seedStartersIfEmpty(in: modesDir)
        return ["Re-seeded \(ModeStore.starterModes().count) starter modes in \(modesDir.path)."]
    }

    private func wipeConfig() -> [String] {
        var actions: [String] = []
        let kept = "models"
        let contents = (try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        for item in contents where item.lastPathComponent != kept {
            try? fileManager.removeItem(at: item)
        }
        actions.append("Wiped config under \(supportDir.path) (kept \(kept)/).")
        actions += clearOnboarding()
        actions += clearHUDPosition()
        return actions
    }

    private func wipeAll() -> [String] {
        try? fileManager.removeItem(at: supportDir)
        var actions = ["Removed \(supportDir.path) entirely (including downloaded models)."]
        actions += clearOnboarding()
        actions += clearHUDPosition()
        return actions
    }

    private func clearHUDPosition() -> [String] {
        HUDAnchorStore.clear(defaults)
        return ["Reset HUD position to the default."]
    }
}
