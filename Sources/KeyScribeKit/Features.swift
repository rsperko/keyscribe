import Foundation

// The single source of truth for in-development feature flags. Each case is one opt-in toggle that
// appears under Settings → Advanced → Experimental Features and is read at its gate via
// `settings.features.isEnabled(.someFlag)`.
//
// Adding a feature:  add a case here (with id/title/summary), then gate the code on
//                    `settings.features.isEnabled(.newCase)`. The toggle renders automatically.
// Rolling it out:    delete the case and make the gate unconditional. A stale id left in a user's
//                    settings.toml is ignored and dropped on the next write.
//
// Flags are strictly opt-in: an unset flag is off. There is deliberately no per-flag default-on —
// a feature is exercised by toggling it on, then rolled out by deleting the case (never by flipping
// a default), so a half-built feature can never silently ship enabled.
//
// The enum ships with no cases — that is the intended empty state (the UI section hides itself when
// `allCases` is empty). The `switch self` bodies below become exhaustive as soon as a case exists.
// `id` is the stable TOML key; keep it snake_case and unique across cases (FeaturesTests guards
// uniqueness), and never rename it once a build has shipped it.
public enum Feature: CaseIterable, Hashable, Sendable {
    public var id: String {
        switch self {}
    }

    public var title: String {
        switch self {}
    }

    public var summary: String {
        switch self {}
    }
}
