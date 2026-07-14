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
}
