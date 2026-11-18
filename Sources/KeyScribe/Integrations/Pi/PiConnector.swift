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

    static func turnedOff(setupFolder: URL, pluginDir: URL, home: URL) -> TurnedOff {
        let file = setupFolder.appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: file.path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = settings["extensions"]
        else { return .no }
        guard let entries = listed as? [String] else { return .unknown(unreadable(file)) }
        return PiExtensionSettings.excludes(entries, pluginDir: pluginDir.path, setupFolder: setupFolder.path, home: home.path) ? .yes : .no
    }

    private static func unreadable(_ file: URL) -> String {
        "The extensions setting in \(ConnectorFolders.display(file)) is not a list of entries, so whether Pi has the connector turned off is unknown."
    }
}

extension ExtensionAgent {
    static let pi = ExtensionAgent(
        kind: .pi,
        rule: .pi,
        keepsPluginName: true,
        extraFolders: { PiCLI.extraFolders(home: $0) },
        minimumVersion: PiCLI.minimumVersion,
        version: { PiCLI.version(in: $0) },
        turnedOff: { PiCLI.turnedOff(setupFolder: $0.setupFolder, pluginDir: $0.pluginDir, home: $0.home) },
        recognizedFiles: ["settings.json", "auth.json", "models.json", "extensions", "sessions"],
        wording: .init(disabledAdvice: "Turn the extension back on in Pi.", updateStep: "Update Pi", alsoSearched: ["under Node version managers"]))
}
