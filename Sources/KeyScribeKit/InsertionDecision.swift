public struct TargetSnapshot: Equatable, Sendable {
    public var bundleId: String?
    // The exact process that owned focus when the snapshot was taken. Two apps can share a bundle id, so
    // secure-field state, context, and insertion must all be bound to this pid — not just the bundle id.
    // Int32 (not pid_t) keeps KeyScribeKit free of a Darwin dependency; the app passes processIdentifier.
    public var pid: Int32?
    public var focusedWindowId: String?
    // Best-effort secure-field signal; secure dictation is diverted to concealed clipboard delivery.
    public var isSecureField: Bool
    // AX role of the focused element from the same walk that read the secure flag — the source for
    // content-free field facts (FieldFacts.derive). Best-effort; nil claims nothing.
    // SNAPSHOT-TIME QUALITY HINT, and weaker than `isSecureField` beside it: the secure flag is
    // re-probed at commit (DictationController's commitSecureProbe) and OR-ed into the adopted
    // snapshot, because getting it wrong leaks a password. The role is read once at dictation start
    // and never revalidated, so a focus move to a different field in the same window can leave it
    // stale — a single-line rule could then be applied to a text area, or missed on one. Accepted:
    // the worst case is a formatting hint that does not match the destination, which the user sees
    // and can undo atomically. Do not reuse this field for anything where staleness is unsafe.
    public var focusedRole: String?

    public init(
        bundleId: String?, pid: Int32? = nil, focusedWindowId: String? = nil,
        isSecureField: Bool = false, focusedRole: String? = nil
    ) {
        self.bundleId = bundleId
        self.pid = pid
        self.focusedWindowId = focusedWindowId
        self.isSecureField = isSecureField
        self.focusedRole = focusedRole
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
