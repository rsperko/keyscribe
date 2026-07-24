import Foundation

// Merge freshly-measured benchmark engine rows into any previously-written rows for the same file.
// A filtered run (`--benchmark … --engines a,b`) measures only some engines; without merging, writing the
// results file would drop every other engine's row. `replace` (a full-fleet run, no engine filter) discards
// the old rows and keeps only the fresh set; otherwise the fresh rows overlay the existing map by id,
// preserving engines the run did not touch.
public enum BenchmarkResultsMerge {
    public static func merged<Row>(
        existing: [String: Row], fresh: [String: Row], replace: Bool
    ) -> [String: Row] {
        if replace { return fresh }
        var out = existing
        for (id, row) in fresh { out[id] = row }
        return out
    }
}
