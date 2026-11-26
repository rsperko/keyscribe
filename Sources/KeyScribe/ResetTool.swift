import Foundation
import KeyScribeKit

enum ResetTarget: String, CaseIterable {
    case onboarding, modes, config, permissions, all, eraseAll
}

struct ResetTool {
    static let firstRunKey = "didCompleteFirstRun"
    static let accessibilityAtLastLaunchKey = "accessibilityGrantedAtLastLaunch"
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
    var modelLoadDiagFile: URL = KeyScribePaths.modelLoadDiagFile
    var requestAdaptationsFile: URL = KeyScribePaths.requestAdaptationsFile
    var wireOverridesFile: URL = KeyScribePaths.wireOverridesFile
    var temporaryDir: URL = FileManager.default.temporaryDirectory
    var isProcessAlive: (Int32) -> Bool = CaptureLeftovers.isRunning
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
        actions += eraseInterruptedRecordings()
        actions += eraseAgentClipboard()
        let leftFiles = [modelLoadDiagFile, requestAdaptationsFile, wireOverridesFile].filter { !fileManager.removeIfPresent($0) }
        if !leftFiles.isEmpty {
            actions.append("Could not erase \(leftFiles.map(\.path).joined(separator: ", ")).")
        }
        actions += eraseKeychain()
        return actions
    }

    // The archive lives OUTSIDE supportDir (so a WAV can't fire the config watcher), so no supportDir wipe
    // reaches it. It holds raw speech, so the erase must name it explicitly or "permanently delete" is a lie.
    private func eraseCaptureArchive() -> [String] {
        guard !fileManager.isMissing(captureArchiveDir) else { return [] }
        let count = (try? fileManager.contentsOfDirectory(at: captureArchiveDir, includingPropertiesForKeys: nil))?.count
        guard fileManager.removeIfPresent(captureArchiveDir) else {
            return ["Could not erase the retained recordings in \(captureArchiveDir.path)."]
        }
        switch count {
        case 0: return []
        case let count?: return ["Erased \(count) retained recording\(count == 1 ? "" : "s") from \(captureArchiveDir.path)."]
        case nil: return ["Erased the retained recordings in \(captureArchiveDir.path)."]
        }
    }

    private func eraseInterruptedRecordings() -> [String] {
        let count = CaptureLeftovers.sweep(in: temporaryDir, isAlive: isProcessAlive)
        guard count > 0 else { return [] }
        return ["Erased \(count) recording\(count == 1 ? "" : "s") left behind by an interrupted dictation."]
    }

    private func eraseAgentClipboard() -> [String] {
        let folder = AgentClipboard.folder(in: temporaryDir)
        guard !fileManager.isMissing(folder) else { return [] }
        let count = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.count
        guard fileManager.removeIfPresent(folder) else {
            return ["Could not erase the clipboard files saved for agents in \(folder.path)."]
        }
        switch count {
        case 0: return []
        case let count?: return ["Erased \(count) clipboard file\(count == 1 ? "" : "s") saved for agents."]
        case nil: return ["Erased the clipboard files saved for agents."]
        }
    }

    private func removeChildren(of folder: URL, keeping keep: (URL) -> Bool) -> [String]? {
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return fileManager.isMissing(folder) ? [] : nil
        }
        return contents.filter { !keep($0) && !fileManager.removeIfPresent($0) }.map(\.lastPathComponent)
    }

    private func leftLine(_ left: [String]?, in folder: URL) -> String? {
        guard let left else { return "Could not read \(folder.path) to reset it." }
        guard !left.isEmpty else { return nil }
        return "Could not remove \(left.sorted().joined(separator: ", ")) from \(folder.path)."
    }

    private static func eraseKeychainKeys() -> [String] {
        guard let count = KeychainStore.deleteAll() else {
            return ["Could not confirm that saved AI keys were erased from the Keychain. Check Keychain Access."]
        }
        return ["Erased \(count) saved AI key\(count == 1 ? "" : "s") from the Keychain."]
    }

    private func clearOnboarding() -> [String] {
        defaults.removeObject(forKey: Self.firstRunKey)
        defaults.removeObject(forKey: Self.accessibilityAtLastLaunchKey)
        VoiceCommandNotices(supportDir: supportDir, defaults: defaults).clear()
        return ["Cleared onboarding flag (\(Self.firstRunKey))."]
    }

    private func reseedModes() -> [String] {
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        // Drop the last-known-good and seed ledger too, so a re-seed can't resurrect a pre-reset mode.
        let lkgDir = supportDir.appendingPathComponent("lkg", isDirectory: true)
        let left = [modesDir, lkgDir].filter { !fileManager.removeIfPresent($0) }
        try? fileManager.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { ModeStore.ensureSystemModes(in: modesDir) }
        guard left.isEmpty else {
            return ["Could not reset modes: \(left.map(\.path).joined(separator: ", ")) could not be removed."]
        }
        ModeStore.recordStarterOffersIfFresh(in: modesDir, ledgerDir: lkgDir)
        return ["Reset modes: recorded \(ModeStore.starterModes().count) starter templates as offers in \(modesDir.path)."]
    }

    private func wipeConfig() -> [String] {
        var actions: [String] = []
        let kept = "models"
        let left = removeChildren(of: supportDir) {
            $0.lastPathComponent == kept || ConfigWatchFilter.isIgnoredTopLevelFile($0.lastPathComponent)
        }
        actions.append(leftLine(left, in: supportDir)
            ?? "Wiped config under \(supportDir.path) (kept \(kept)/ and the agent instruction files).")
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
            let left = removeChildren(of: supportDir) { $0.standardizedFileURL.path == modelsPath }
            actions = [leftLine(left, in: supportDir) ?? "Reset all config under \(supportDir.path); shared downloaded models kept."]
        } else {
            // Dev: models cache lives outside supportDir, so the whole dir is safe to drop.
            actions = [fileManager.removeIfPresent(supportDir)
                ? "Removed \(supportDir.path); shared downloaded models kept."
                : "Could not remove \(supportDir.path)."]
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

    // For resets a user clicks: off the caller's thread and terminated past its budget, so a wedged tccd can
    // neither freeze the UI nor strand the action.
    static func runBounded(_ executableURL: URL, _ arguments: [String], timeoutSeconds: Double) async -> TCCResetOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            let status = try await runWithDeadline(seconds: timeoutSeconds) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
            }
            return status == 0 ? .reset : .failed(exitCode: status)
        } catch is DeadlineExceeded {
            if process.isRunning { process.terminate() }
            return .timedOut
        } catch {
            return .launchFailed
        }
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
