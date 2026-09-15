import ApplicationServices
import Foundation

enum TCCResetOutcome: Equatable, Sendable {
    case reset
    case failed(exitCode: Int32)
    case timedOut
    case launchFailed
}

@MainActor
final class AccessibilityRecovery: ObservableObject {
    static let shared = AccessibilityRecovery()

    @Published private(set) var isResetting = false
    @Published private(set) var didAttemptReset = false
    @Published private(set) var resetFailed = false

    private let isTrusted: @MainActor () -> Bool
    private let bundleID: String?
    private let resetService: @MainActor (_ service: String, _ bundleID: String) async -> TCCResetOutcome
    private let requestAccess: @MainActor () -> Void

    init(
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        bundleID: String? = Bundle.main.bundleIdentifier,
        resetService: @escaping @MainActor (_ service: String, _ bundleID: String) async -> TCCResetOutcome = { service, bundleID in
            await ResetTool.runBounded(URL(fileURLWithPath: "/usr/bin/tccutil"), ["reset", service, bundleID], timeoutSeconds: 5)
        },
        requestAccess: @escaping @MainActor () -> Void = { _ = Permissions.accessibilityStatus(prompt: true) }
    ) {
        self.isTrusted = isTrusted
        self.bundleID = bundleID
        self.resetService = resetService
        self.requestAccess = requestAccess
    }

    // An entry granted to a differently signed build of this app still shows as on but no longer applies, and
    // macOS won't prompt while it exists, so clear it first. At most once per process: if this process can't
    // observe a grant made after the reset, a second reset would delete that grant.
    func request() async {
        guard !isResetting, !isTrusted() else { return }
        guard !didAttemptReset, let bundleID else {
            requestAccess()
            return
        }
        didAttemptReset = true
        isResetting = true
        let outcome = await resetService("Accessibility", bundleID)
        isResetting = false
        resetFailed = outcome != .reset
        if resetFailed {
            Log.config.error("accessibility reset failed: \(String(describing: outcome), privacy: .public)")
        }
        requestAccess()
    }
}
