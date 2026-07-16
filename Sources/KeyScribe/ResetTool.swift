import Foundation
import KeyScribeKit

enum ResetTarget: String, CaseIterable {
    case onboarding, modes, config, permissions, all, eraseAll
}

struct ResetTool {
    static let firstRunKey = "didCompleteFirstRun"
    // TCC service names as `tccutil` expects them: Automation grants live under "AppleEvents".
    static let tccServices = ["Microphone", "Accessibility", "AppleEvents"]

    let supportDir: URL
    let defaults: UserDefaults
    var fileManager: FileManager = .default
    // The shared models cache, preserved by every reset. Nested inside supportDir for production; outside it
    // (under the production folder) for the dev variant.
    var modelsDir: URL = KeyScribePaths.modelsDir
    // Retained capture WAVs (`[audio] keep_captures`). A sibling of supportDir, so no supportDir wipe reaches
    // it — but it is raw user speech, which is exactly what an erase promises to destroy.
    var captureArchiveDir: URL = KeyScribePaths.captureArchiveDir
    var bundleID: String = Bundle.main.bundleIdentifier ?? "com.keyscribe.app"
    // Test seam: dispatch without touching the real TCC database.
    var resetTCCService: (_ service: String, _ bundleID: String) -> String = ResetTool.tccutilReset
    // Test seam: erase without touching the real Keychain.
    var eraseKeychain: () -> [String] = ResetTool.eraseKeychainKeys

    @discardableResult
    func run(_ target: ResetTarget) -> [String] {
        switch target {
        case .onboarding: return clearOnboarding()
        case .modes: return reseedModes()
        case .config: return wipeConfig()
        case .permissions: return resetPermissions()
        case .all: return wipeAll()
        case .eraseAll: return eraseAllData()
        }
    }

    // The full user-facing erase: wipe the support dir (shared models kept), any retained capture WAVs, and
    // the variant's BYOK Keychain keys. TCC grants are deliberately left alone — they're system permissions,
    // not KeyScribe data, and resetting them mid-run would break the live mic/event tap.
    private func eraseAllData() -> [String] {
        var actions = wipeAll()
        actions += eraseCaptureArchive()
        actions += eraseKeychain()
        return actions
    }

    // The archive lives OUTSIDE supportDir (so a WAV can't fire the config watcher), so no supportDir wipe
    // reaches it. It holds raw speech, so the erase must name it explicitly or "permanently delete" is a lie.
    private func eraseCaptureArchive() -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(at: captureArchiveDir, includingPropertiesForKeys: nil)) ?? []
        guard !contents.isEmpty else { return [] }
        try? fileManager.removeItem(at: captureArchiveDir)
        return ["Erased \(contents.count) retained recording\(contents.count == 1 ? "" : "s") from \(captureArchiveDir.path)."]
    }

    private static func eraseKeychainKeys() -> [String] {
        let count = KeychainStore.deleteAll()
        return ["Erased \(count) saved AI key\(count == 1 ? "" : "s") from the Keychain."]
    }

    private func clearOnboarding() -> [String] {
        defaults.removeObject(forKey: Self.firstRunKey)
        return ["Cleared onboarding flag (\(Self.firstRunKey))."]
    }

    private func reseedModes() -> [String] {
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? fileManager.removeItem(at: modesDir)
        try? fileManager.createDirectory(at: modesDir, withIntermediateDirectories: true)
        // Drop the last-known-good and seed ledger too, so a re-seed can't resurrect a pre-reset mode.
        let lkgDir = supportDir.appendingPathComponent("lkg", isDirectory: true)
        try? fileManager.removeItem(at: lkgDir)
        ModeStore.recordStarterOffersIfFresh(in: modesDir, ledgerDir: lkgDir)
        ModeStore.ensureSystemModes(in: modesDir)
        return ["Reset modes: recorded \(ModeStore.starterModes().count) starter templates as offers in \(modesDir.path)."]
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
            // Production: models cache nested in supportDir — drop every other child so the multi-gigabyte
            // download (shared with the dev variant) survives.
            let contents = (try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
            for item in contents where item.standardizedFileURL.path != modelsPath {
                try? fileManager.removeItem(at: item)
            }
            actions = ["Reset all config under \(supportDir.path); shared downloaded models kept."]
        } else {
            // Dev: models cache lives outside supportDir, so the whole dir is safe to drop.
            try? fileManager.removeItem(at: supportDir)
            actions = ["Removed \(supportDir.path); shared downloaded models kept."]
        }
        actions += clearOnboarding()
        actions += clearHUDPosition()
        return actions
    }

    // Removes the app's TCC grants so macOS re-prompts on the next launch. No sudo needed (tccutil mutates
    // the current user's database); the live process keeps its cached verdicts until it relaunches.
    private func resetPermissions() -> [String] {
        var actions = Self.tccServices.map { resetTCCService($0, bundleID) }
        actions.append("Relaunch to be re-prompted (try --setup-permissions or --first-run to walk through granting again).")
        return actions
    }

    // Clears the app's Input Monitoring (ListenEvent) TCC record. KeyScribe never requests it, but a build
    // that called tapCreate before Accessibility was granted could leave a denied ListenEvent record that
    // permanently suppresses the modifier-only event tap. Resetting on a permission relaunch repairs such
    // installs (no-op on a healthy machine).
    @discardableResult
    static func resetInputMonitoring(bundleID: String = Bundle.main.bundleIdentifier ?? "com.keyscribe.app") -> String {
        tccutilReset("ListenEvent", bundleID)
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
