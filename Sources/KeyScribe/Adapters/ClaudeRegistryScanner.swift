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

    static let startLead: TimeInterval = 120

    static func stillRunning(_ remembered: RememberedName) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(remembered.pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return true }
        guard size > 0 else { return false }
        let start = info.kp_proc.p_starttime
        let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        let recorded = TimeInterval(remembered.startedAt) / 1000
        return started <= recorded + 1 && started >= recorded - startLead
    }
}
