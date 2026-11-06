import Darwin
import Foundation
import KeyScribeKit

enum ClaudeRegistryScanner {
    static func defaultConfigDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func scan(configDirs: [URL]) -> [ClaudeRegistryEntry] {
        configDirs.flatMap { dir -> [ClaudeRegistryEntry] in
            let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { (try? Data(contentsOf: $0)).flatMap(ClaudeRegistryEntry.decode) }
                .filter { isRunning(pid: $0.pid) }
        }
    }

    private static func isRunning(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
