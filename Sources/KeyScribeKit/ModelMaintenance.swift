import Foundation

// Pure reconciliation between the install marker (intent) and what is actually on disk (reality).
// The caller supplies which known engine ids have complete model files on disk; this decides the
// marker's new contents and which directories are safe to delete. A complete-but-unmarked model is
// adopted (a download that finished right before a crash is recovered, never deleted); a partial dir
// of a known-but-incomplete engine is an orphan to remove. Directories owned by an engine that stays
// installed are always kept — including a partial bias model the SDK will self-heal on next load.
//
// The models dir is SHARED across build variants (dev + prod side by side) and across app versions,
// so this binary is not the sole authority over its contents. It therefore never touches a directory
// it does not recognize (an id absent from `owned` — a newer build's engine or the other variant's
// in-flight download), never deletes a dir the caller flags as recently modified (`protectedDirs`,
// an active cross-variant download), and preserves marker ids it does not know (`markedIds`) so the
// rewrite unions rather than clobbers the other variant's install bookkeeping.
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
        markedIds: Set<String> = [],
        protectedDirs: Set<String> = [],
        keep: Set<String> = []
    ) -> Plan {
        let complete = Set(knownIds.filter { completeIds.contains($0) })
        let installed = complete.union(markedIds.subtracting(knownIds))

        let ownedByKnown = Set(knownIds.flatMap { owned[$0] ?? [] })
        let keepDirs = Set(complete.flatMap { owned[$0] ?? [] }).union(keep)
        let removeDirs = dirsOnDisk
            .intersection(ownedByKnown)
            .subtracting(keepDirs)
            .subtracting(protectedDirs)
        return Plan(installed: installed, removeDirs: removeDirs)
    }
}
