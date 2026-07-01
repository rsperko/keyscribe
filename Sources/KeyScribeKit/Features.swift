import Foundation

// The single source of truth for in-development feature flags. Each value is one opt-in toggle that
// appears under Settings → Advanced → Experimental Features and is read at its gate via
// `settings.features.isEnabled(.someFlag)`.
//
// Adding a feature:  add a `static let` below with a unique snake_case id, list it in `allCases`,
//                    then gate the code on `settings.features.isEnabled(.newFlag)`. The toggle
//                    renders automatically.
// Rolling it out:    delete the `static let` and its `allCases` entry, and make the gate
//                    unconditional. A stale id left in a user's settings.toml is ignored and dropped
//                    on the next write.
//
// Flags are strictly opt-in: an unset flag is off. There is deliberately no per-flag default-on —
// a feature is exercised by toggling it on, then rolled out by deleting it (never by flipping a
// default), so a half-built feature can never silently ship enabled.
//
// The registry ships with no cases — that is the intended empty state (the UI section hides itself
// when `allCases` is empty). Modeled as a struct with an empty catalog rather than an empty enum so
// the empty state does not read to the compiler as unreachable code. `id` is the stable TOML key;
// keep it snake_case and unique across cases (FeaturesTests guards uniqueness), and never rename it
// once a build has shipped it.
public struct Feature: CaseIterable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String

    public static let allCases: [Feature] = []
}
