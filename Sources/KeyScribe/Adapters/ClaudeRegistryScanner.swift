import Darwin
import Foundation
import KeyScribeKit

enum ClaudeRegistryScanner {
    struct Scan: Equatable, Sendable {
        var entries: [ClaudeRegistryEntry]
        var unreadable: [String]
        var folders: [String] = []
        var processesUnreadable = false
    }

    static func scan(configDirs: [URL]) -> [ClaudeRegistryEntry]? {
        let found = scanEach(configDirs: configDirs)
        return found.unreadable.isEmpty ? found.entries : nil
    }

    static func scanEach(configDirs: [URL]) -> Scan {
        var entries: [ClaudeRegistryEntry] = []
        var unreadable: [String] = []
        for dir in configDirs {
            switch scan(dir) {
            case let found?: entries += found
            case nil: unreadable.append(dir.path)
            }
        }
        return Scan(entries: entries, unreadable: unreadable)
    }

    private static func scan(_ dir: URL) -> [ClaudeRegistryEntry]? {
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        var entries: [ClaudeRegistryEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { return nil }
            switch ClaudeRegistryEntry.read(data) {
            case .interactive(var entry) where isRunning(pid: entry.pid):
                entry.configDir = dir.path
                entries.append(entry)
            case .interactive, .other: continue
            case .invalid: return nil
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
