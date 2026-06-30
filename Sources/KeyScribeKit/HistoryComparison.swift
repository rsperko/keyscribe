import Foundation

// How a History entry is broken into comparison stages (Heard → Inserted, and — when a cloud rewrite
// was involved — the local "On this Mac" step and the "AI rewrite" step). Pure so the gating is verified
// independently of the SwiftUI view and any hand-made preview data.
public enum HistoryComparison {
    public enum Stage: String, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
        case heardInserted
        case onThisMac
        case rewrite
        public var id: String { rawValue }
    }

    // The local/cloud breakdown is meaningful only when a cloud rewrite was involved — that is the
    // boundary it explains. It gates on `cloudInvolved`, never on `transformed`: that field is the
    // on-device intermediate and equals `heard` on a local no-op, so gating on it would hide the
    // rewrite breakdown for exactly the entries that need it.
    public static func stages(cloudInvolved: Bool) -> [Stage] {
        cloudInvolved ? [.heardInserted, .onThisMac, .rewrite] : [.heardInserted]
    }

    // The text after local processing, before any cloud rewrite. `transformed` is nil only on older
    // entries written before it was captured; for those the pre-rewrite text is the heard text itself
    // — never the final result.
    public static func onThisMacText(heard: String, transformed: String?) -> String {
        transformed ?? heard
    }

    public static func texts(
        for stage: Stage, heard: String, transformed: String?, result: String
    ) -> (from: String, to: String) {
        let local = onThisMacText(heard: heard, transformed: transformed)
        switch stage {
        case .heardInserted: return (heard, result)
        case .onThisMac: return (heard, local)
        case .rewrite: return (local, result)
        }
    }
}
