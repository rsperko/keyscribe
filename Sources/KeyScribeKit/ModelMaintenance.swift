import Foundation

// Pure reconciliation between the install marker (intent) and what is on disk (reality). The caller supplies
// which known engine ids have complete files; this decides the marker's new contents and which dirs are safe to
// delete. A complete-but-unmarked model is adopted (a download that finished right before a crash is recovered);
// a partial dir of a known-but-incomplete engine is an orphan to remove; dirs owned by a still-installed engine
// are always kept (including a partial bias model the SDK will self-heal on next load).
//
// The models dir is SHARED across build variants and app versions, so this binary is not the sole authority over
// it. It therefore never touches a dir it does not recognize (an id absent from `owned`), never deletes one the
// caller flags recently modified (`protectedDirs`, an active cross-variant download), and preserves marker ids it
// does not know (`markedIds`) so the rewrite unions rather than clobbers the other variant's bookkeeping.
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
