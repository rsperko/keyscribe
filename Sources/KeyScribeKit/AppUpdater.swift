import Foundation

// Optional, injected update mechanism. The UI is wired to a passive update affordance; builds that
// do not inject an updater keep it inert.
@MainActor
public protocol AppUpdater: AnyObject {
    // The implementation decides whether it is actually time to check.
    func dictationDidFinish()

    // Set by the host; the updater invokes it when an update becomes available.
    var onUpdateAvailable: (@MainActor () -> Void)? { get set }

    func performUpdate()

    // Settings shows the beta switch, in the updater's own words, only for an updater that can honor it.
    var betaOption: BetaUpdateOption? { get }

    func setReceivesBetaUpdates(_ beta: Bool)
}

extension AppUpdater {
    public var betaOption: BetaUpdateOption? { nil }

    public func setReceivesBetaUpdates(_ beta: Bool) {}
}

public struct BetaUpdateOption: Equatable, Sendable {
    public let label: String
    public let help: String

    public init(label: String, help: String) {
        self.label = label
        self.help = help
    }
}

// The release scripts tag a prerelease's appcast item with this channel name; stable items carry none.
public enum UpdateChannels {
    public static let beta = "beta"

    public static func allowed(beta: Bool) -> Set<String> {
        beta ? [Self.beta] : []
    }
}

// Sparkle asks for a fresh check after a user changes what it may find, not on every launch, so the first
// choice is only recorded.
public struct UpdateChannelSelection: Sendable {
    public private(set) var allowed: Set<String> = []
    private var chosen = false

    public init() {}

    public mutating func select(beta: Bool) -> Bool {
        let channels = UpdateChannels.allowed(beta: beta)
        defer { chosen = true }
        guard channels != allowed else { return false }
        allowed = channels
        return chosen
    }
}
