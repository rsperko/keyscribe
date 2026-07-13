import Foundation

// Materializing a starter template on demand (design.md §5.1, UX2 phase 4). A template written at its
// free catalog id IS a seed — it keeps `seedId`/`seedVersion` so reconcile keeps applying future seed
// updates until the user edits it. A second copy (catalog id already taken) is a plain user mode at a
// suffixed id and a suffixed visible name ("Email 2") with no seed identity, so two files never fight
// for one ledger entry and repeated instances stay distinguishable in Your Modes.
public enum ModeTemplateInstantiation {
    public enum Materialization: Equatable, Sendable {
        case seed(Mode)
        case copy(Mode)

        public var mode: Mode {
            switch self {
            case .seed(let mode), .copy(let mode): return mode
            }
        }
    }

    public static func materialize(template: Mode, existing: [Mode], connections: [Connection]) -> Materialization {
        var mode = template
        // Added modes land Disabled (option-1-rollout.md): the user reviews/wires the seeded editor and flips
        // Enabled when ready, so nothing goes live and starts failing (e.g. an AI-rewrite mode with no wired
        // service) the instant it is added. Callers that add AND finish setup in one step (first-run) re-enable
        // explicitly.
        mode.enabled = false
        // Drop any trigger already held by an ENABLED existing mode so materializing never silently steals a
        // live shortcut (generalizes `fnIsFree`); stored keys are canonical, compared case-insensitively.
        let taken = Set(existing.filter(\.enabled).flatMap { $0.triggerKeys.map { $0.key.lowercased() } })
        mode.triggerKeys = mode.triggerKeys.filter { !taken.contains($0.key.lowercased()) }
        // Prefill the rewrite connection only when the choice is unambiguous (exactly one exists).
        if mode.aiRewrite != nil, connections.count == 1 {
            mode.aiRewrite?.connection = connections[0].id
        }
        if existing.contains(where: { $0.id == template.id }) {
            mode.id = ModeStore.newID(for: template.name, existing: existing.map(\.id))
            mode.name = ModeStore.uniqueName(for: template.name, existing: existing.map(\.name))
            mode.seedId = nil
            mode.seedVersion = nil
            return .copy(mode)
        }
        return .seed(mode)
    }
}
