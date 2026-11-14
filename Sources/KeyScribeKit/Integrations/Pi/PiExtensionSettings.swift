import Foundation

public enum PiExtensionSettings {
    public static func excludes(_ entries: [String], pluginDir: String, setupFolder: String, home: String) -> Bool {
        let targets = [pluginDir, pluginDir + "/index.ts"].map { FolderPath.resolve($0, home: home, relativeTo: "/") }
        func matches(_ entry: String, glob: Bool) -> Bool {
            let pattern = FolderPath.resolve(String(entry.dropFirst()), home: home, relativeTo: setupFolder)
            return targets.contains { glob ? fnmatch(pattern, $0, 0) == 0 : pattern == $0 }
        }
        func any(_ prefix: Character, glob: Bool = false) -> Bool { entries.contains { $0.first == prefix && matches($0, glob: glob) } }
        return any("-") || (any("!", glob: true) && !any("+"))
    }
}
