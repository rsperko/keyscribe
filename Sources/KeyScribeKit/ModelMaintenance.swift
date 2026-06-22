import Foundation

// Pure reconciliation between the install marker (intent) and what is actually on disk (reality).
// The caller supplies which known engine ids have complete model files on disk; this decides the
// marker's new contents and which directories are safe to delete. A complete-but-unmarked model is
// adopted (a download that finished right before a crash is recovered, never deleted); an incomplete
// or unknown directory is an orphan to remove. Directories owned by an engine that stays installed
// are always kept — including a partial bias model the SDK will self-heal on next load.
public enum ModelMaintenance {
    public struct Plan: Equatable, Sendable {
        public let installed: Set<String>
        public let removeDirs: Set<String>

        public init(installed: Set<String>, removeDirs: Set<String>) {
            self.installed = installed
            self.removeDirs = removeDirs
        }
    }

    public static func reconcile(
        knownIds: [String],
        owned: [String: [String]],
        completeIds: Set<String>,
        dirsOnDisk: Set<String>,
        keep: Set<String> = []
    ) -> Plan {
        let installed = Set(knownIds.filter { completeIds.contains($0) })
        let keepDirs = Set(installed.flatMap { owned[$0] ?? [] }).union(keep)
        let removeDirs = dirsOnDisk.subtracting(keepDirs)
        return Plan(installed: installed, removeDirs: removeDirs)
    }
}
