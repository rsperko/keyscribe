import Foundation

// Merge freshly-measured benchmark engine rows into any previously-written rows for the same file.
// A filtered run (`--benchmark … --engines a,b`) measures only some engines; without merging, writing the
// results file would drop every other engine's row. `replace` (a full-fleet run, no engine filter) discards
// the old rows and keeps only the fresh set; otherwise the fresh rows overlay the existing map by id,
// preserving engines the run did not touch. `dropping` removes engines that failed this run.
public enum BenchmarkResultsMerge {
    public static func merged<Row>(
        existing: [String: Row], fresh: [String: Row], replace: Bool, dropping: Set<String> = []
    ) -> [String: Row] {
        var out = replace ? fresh : existing.merging(fresh) { $1 }
        for id in dropping { out[id] = nil }
        return out
    }
}
