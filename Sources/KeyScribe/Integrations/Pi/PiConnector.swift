import Foundation
import KeyScribeKit

enum PiCLI {
    static let minimumVersion = [1, 4, 0]

    static func extraFolders(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        listing: (URL) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
    ) -> [String] {
        let nodeVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvm = listing(nodeVersions).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nodeVersions.appendingPathComponent($0).appendingPathComponent("bin").path }
        return nvm + [".bun/bin", ".npm-global/bin"].map { home.appendingPathComponent($0).path }
    }

    static func version(in output: String) -> [Int]? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard let word = words.last, words.count == 1 || (words.count == 2 && words[0] == "pi") else { continue }
            let numeric = word.hasPrefix("v") ? word.dropFirst() : word
            let core = numeric.prefix { $0.isNumber || $0 == "." }
            guard !core.isEmpty, core.endIndex == numeric.endIndex || numeric[core.endIndex] == "-" else { continue }
            let parts = core.split(separator: ".").map { Int($0) }
            guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { continue }
            var version = parts.compactMap { $0 }
            while version.count < minimumVersion.count { version.append(0) }
            return version
        }
        return nil
    }

    static func turnedOff(setupFolder: URL, pluginDir: URL, home: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: setupFolder.appendingPathComponent("settings.json").path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = settings["extensions"] as? [String]
        else { return false }
        return PiExtensionSettings.excludes(entries, pluginDir: pluginDir.path, setupFolder: setupFolder.path, home: home.path)
    }
}

extension ExtensionAgent {
    static let pi = ExtensionAgent(
        kind: .pi,
        rule: .pi,
        toolProgram: "pi",
        extensionName: { $0 },
        defaultFolder: { $0.appendingPathComponent(".pi/agent", isDirectory: true) },
        extraFolders: { PiCLI.extraFolders(home: $0) },
        minimumVersion: PiCLI.minimumVersion,
        version: { PiCLI.version(in: $0) },
        turnedOff: { PiCLI.turnedOff(setupFolder: $0.setupFolder, pluginDir: $0.pluginDir, home: $0.home) ? .yes : .no },
        recognizedFiles: ["settings.json", "auth.json", "models.json", "extensions", "sessions"],
        copy: AgentConnectorCopy(
            help: "\(Branding.appName) reaches Pi through a small extension installed in the folder Pi loads its configuration from. Installed means the extension is in place; each conversation using this folder then connects on its own, unless you disconnect it.",
            reloadHint: "Already running Pi here? Run /reload in each open conversation.",
            uninstallTitle: "Uninstall the Pi connector from this folder?",
            uninstallMessage: "Pi conversations using this folder disconnect now, and new ones will not connect. Work you already sent may still finish. Each open conversation unloads the connector when you run /reload in it or restart it. Other folders stay connected. The folder, its conversations, your conversation names and disconnections, and other \(Branding.appName) settings are kept.",
            toolNotFoundLabel: "Pi not found",
            toolNotFoundAdvice: "Install Pi, or choose the pi command yourself. \(Branding.appName) looked for it in a running conversation, your login shell\u{2019}s PATH, its own PATH, the usual install folders, and under Node version managers.",
            toolNotWorkingLabel: "Pi not working",
            unavailable: "This copy of \(Branding.appName) is missing its Pi connector. Reinstall \(Branding.appName) to connect Pi.",
            disabledLabel: "Turned off in Pi",
            disabledAdvice: "Turn the extension back on in Pi.",
            removalUnfinishedAdvice: "The connector was uninstalled in \(Branding.appName), but its folder is still in Pi\u{2019}s extensions. Its sessions no longer connect. Finish uninstalling it, then install it again if you want it back.",
            listUnreadable: "Pi\u{2019}s extensions folder could not be read.",
            noReason: "Pi did not say why.",
            manualUninstallLead: "To remove the connector from Pi, delete its folder in a terminal, then run /reload in each open session or restart it:",
            manualUninstallAfterDisconnect: "Disconnected from \(Branding.appName). Delete the connector\u{2019}s folder in a terminal to finish uninstalling, then run /reload in each open session or restart it:",
            stillConnected: { count in
                count == 1
                    ? "The connector was removed outside \(Branding.appName), so 1 open session is still connected and keeps receiving what you say until you run /reload in it or restart it."
                    : "The connector was removed outside \(Branding.appName), so \(count) open sessions are still connected and keep receiving what you say until you run /reload in each one or restart them."
            },
            toolTooOldLabel: "Pi too old",
            toolTooOldAdvice: { found in
                "Pi \(found) is older than \(ExtensionAgent.describe(PiCLI.minimumVersion)), the first version the connector works with. Update Pi, then come back here."
            }))
}
