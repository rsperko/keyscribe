public struct TargetSnapshot: Equatable, Sendable {
    public var bundleId: String?
    // The exact process that owned focus when the snapshot was taken. Two apps can share a bundle id, so
    // secure-field state, context, and insertion must all be bound to this pid — not just the bundle id.
    // Int32 (not pid_t) keeps KeyScribeKit free of a Darwin dependency; the app passes processIdentifier.
    public var pid: Int32?
    public var focusedWindowId: String?
    // Best-effort secure-field signal; secure dictation is diverted to concealed clipboard delivery.
    public var isSecureField: Bool

    public init(bundleId: String?, pid: Int32? = nil, focusedWindowId: String? = nil, isSecureField: Bool = false) {
        self.bundleId = bundleId
        self.pid = pid
        self.focusedWindowId = focusedWindowId
        self.isSecureField = isSecureField
    }
}

public enum FallbackReason: Equatable, Sendable {
    case appChanged
    case focusChanged
    case unknownTarget
    case accessibilityDenied
    case secureField
}

public enum InsertionDecision: Equatable, Sendable {
    case insert
    case clipboardFallback(reason: FallbackReason)
}

public func decideInsertion(captured: TargetSnapshot, current: TargetSnapshot) -> InsertionDecision {
    // Secure fields always divert to concealed clipboard delivery.
    if captured.isSecureField || current.isSecureField {
        return .clipboardFallback(reason: .secureField)
    }
    guard let capturedBundle = captured.bundleId else {
        return .clipboardFallback(reason: .unknownTarget)
    }
    guard current.bundleId == capturedBundle else {
        return .clipboardFallback(reason: .appChanged)
    }
    // Require the exact process to match: a same-bundle helper with a different pid is a different target,
    // and a pid known on one side but missing on the other is an indeterminate identity. Both are treated
    // conservatively (divert) rather than inserted on a maybe. Two unknown pids (no pid tracking at all,
    // e.g. a test seam) compare equal and fall through to the bundle/window checks.
    if captured.pid != current.pid {
        return .clipboardFallback(reason: .appChanged)
    }
    if let capturedWindow = captured.focusedWindowId,
       let currentWindow = current.focusedWindowId,
       capturedWindow != currentWindow {
        return .clipboardFallback(reason: .focusChanged)
    }
    return .insert
}

public func pasteLastDivertsToClipboard(
    frontmostBundleId: String?, ownBundleId: String?, accessibilityGranted: Bool
) -> Bool {
    if !accessibilityGranted { return true }
    if let ownBundleId, frontmostBundleId == ownBundleId { return true }
    return false
}

public enum InsertionAction: Equatable, Sendable {
    case paste
    case ax
    case type
    case clipboard
}

public struct ClipboardPaste: Equatable, Sendable {
    public var modifier: Mode.ClipboardModifier
    public var settleMs: Int
    public init(modifier: Mode.ClipboardModifier = .command, settleMs: Int = 0) {
        self.modifier = modifier
        self.settleMs = settleMs
    }
}

public func insertionAction(decision: InsertionDecision, method: Mode.Insertion) -> InsertionAction {
    guard decision == .insert else { return .clipboard }
    switch method {
    case .paste: return .paste
    case .insert: return .ax
    case .type: return .type
    }
}
