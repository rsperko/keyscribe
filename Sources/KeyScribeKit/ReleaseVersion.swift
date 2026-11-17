import Foundation

// The version forms docs/reference/releases_and_updates.md promises: X.Y.Z for a release, X.Y.Z-beta.N for a
// beta, either with an optional leading "v" and an optional "+I" iteration a downstream build appends.
// Order follows the versions alone, never a build number, so it holds for any build's numbering.
public struct ReleaseVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let beta: Int?
    public let iteration: Int

    public var isBeta: Bool { beta != nil }

    public init?(_ text: String) {
        guard let m = text.wholeMatch(of: #/v?(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?(?:\+(\d+))?/#),
              let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        beta = m.4.flatMap { Int($0) }
        iteration = m.5.flatMap { Int($0) } ?? 0
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.key.lexicographicallyPrecedes(rhs.key)
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.key == rhs.key
    }

    private var key: [Int] { [major, minor, patch, beta ?? .max, iteration] }
}

// The rule every updater honors, Sparkle's channels included: nothing older is offered, a release always is,
// and a beta only to someone who turned betas on. Turning betas off therefore keeps the installed beta until a
// newer release arrives.
public enum UpdateOffer {
    public static func shouldOffer(installed: String, candidate: String, betaOn: Bool) -> Bool {
        guard let installed = ReleaseVersion(installed), let candidate = ReleaseVersion(candidate),
              candidate > installed else { return false }
        return betaOn || !candidate.isBeta
    }
}
