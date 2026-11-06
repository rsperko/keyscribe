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

    static func scan(configDirs: [URL]) -> [ClaudeRegistryEntry]? {
        var entries: [ClaudeRegistryEntry] = []
        for dir in configDirs {
            let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
            guard FileManager.default.fileExists(atPath: sessions.path) else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) else { return nil }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file) else { return nil }
                switch ClaudeRegistryEntry.read(data) {
                case .interactive(let entry) where isRunning(pid: entry.pid): entries.append(entry)
                case .interactive, .other: continue
                case .invalid: return nil
                }
            }
        }
        return entries
    }

    private static func isRunning(pid: Int) -> Bool {
        ProcessStart.isRunning(pid: pid)
    }

    static let startLead: TimeInterval = 120

    static func stillRunning(_ remembered: RememberedName) -> Bool {
        ProcessStart.stillRunning(remembered, lead: startLead)
    }
}
