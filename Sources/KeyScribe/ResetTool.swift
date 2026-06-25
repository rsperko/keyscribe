import Foundation
import KeyScribeKit

enum ResetTarget: String, CaseIterable {
    case onboarding, modes, config, permissions, all
}

struct ResetTool {
    static let firstRunKey = "didCompleteFirstRun"
    // TCC service names as `tccutil` expects them: Automation grants live under "AppleEvents".
    static let tccServices = ["Microphone", "Accessibility", "AppleEvents"]

    let supportDir: URL
    let defaults: UserDefaults
    var fileManager: FileManager = .default
    // The shared models cache is preserved by every reset. For production it is nested inside
    // supportDir; for the dev variant it lives under the production folder, outside supportDir.
    var modelsDir: URL = KeyScribePaths.modelsDir
    var bundleID: String = Bundle.main.bundleIdentifier ?? "com.keyscribe.app"
    // Seam so tests can exercise the dispatch without touching the real TCC database.
    var resetTCCService: (_ service: String, _ bundleID: String) -> String = ResetTool.tccutilReset

    @discardableResult
    func run(_ target: ResetTarget) -> [String] {
        switch target {
        case .onboarding: return clearOnboarding()
        case .modes: return reseedModes()
        case .config: return wipeConfig()
        case .permissions: return resetPermissions()
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
        let modelsPath = modelsDir.standardizedFileURL.path
        var actions: [String]
        if modelsPath.hasPrefix(supportDir.standardizedFileURL.path + "/") {
            // Production layout: the shared models cache is nested in supportDir — drop every other
            // child so the multi-gigabyte download (which the dev variant also uses) survives.
            let contents = (try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
            for item in contents where item.standardizedFileURL.path != modelsPath {
                try? fileManager.removeItem(at: item)
            }
            actions = ["Reset all config under \(supportDir.path); shared downloaded models kept."]
        } else {
            // Dev layout: the shared models cache lives outside supportDir, so the whole dir is safe to drop.
            try? fileManager.removeItem(at: supportDir)
            actions = ["Removed \(supportDir.path); shared downloaded models kept."]
        }
        actions += clearOnboarding()
        actions += clearHUDPosition()
        return actions
    }

    // Removes the app's TCC grants (Microphone, Accessibility, Automation) so macOS re-prompts on the
    // next launch. tccutil only mutates the current user's TCC database for this bundle id, so no sudo
    // is needed; the live process keeps its cached verdicts until it relaunches.
    private func resetPermissions() -> [String] {
        var actions = Self.tccServices.map { resetTCCService($0, bundleID) }
        actions.append("Relaunch to be re-prompted (try --setup-permissions or --first-run to walk through granting again).")
        return actions
    }

    private static func tccutilReset(_ service: String, _ bundleID: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return "Reset \(service) for \(bundleID)\(output.isEmpty ? "." : ": \(output)")"
            }
            return "Reset \(service) failed (exit \(process.terminationStatus))\(output.isEmpty ? "." : ": \(output)")"
        } catch {
            return "Reset \(service) failed: \(error.localizedDescription)"
        }
    }

    private func clearHUDPosition() -> [String] {
        HUDAnchorStore.clear(defaults)
        return ["Reset HUD position to the default."]
    }
}
