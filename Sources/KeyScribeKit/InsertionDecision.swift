public struct TargetSnapshot: Equatable, Sendable {
    public var bundleId: String?
    public var focusedWindowId: String?
    // The focused field is a secure (password) text field. The spoken text is itself a secret, so it
    // must never reach a cloud rewrite, never be paired with captured context, and never be persisted —
    // delivery is a concealed clipboard copy, not a synthetic paste (design.md §4.4). Best-effort: set
    // from the AXSecureTextField subrole, which native and WebKit fields expose but some Electron do not.
    public var isSecureField: Bool

    public init(bundleId: String?, focusedWindowId: String? = nil, isSecureField: Bool = false) {
        self.bundleId = bundleId
        self.focusedWindowId = focusedWindowId
        self.isSecureField = isSecureField
    }
}

public enum FallbackReason: Equatable, Sendable {
    case appChanged
    case focusChanged
    case unknownTarget
    // Accessibility is not granted, so no synthetic insertion (⌘V paste, AX-set, or typing) can reach
    // the target — every path needs a trusted process. The only safe delivery is the clipboard, and the
    // outcome must say "copied", never "inserted" (otherwise the text is silently lost).
    case accessibilityDenied
    // The captured or current focused field is a secure (password) field. The dictated text is diverted
    // to a concealed clipboard copy rather than pasted, so it never lands in a password box via ⌘V and
    // clipboard managers do not retain it.
    case secureField
}

public enum InsertionDecision: Equatable, Sendable {
    case insert
    case clipboardFallback(reason: FallbackReason)
}

public func decideInsertion(captured: TargetSnapshot, current: TargetSnapshot) -> InsertionDecision {
    // A secure field on either end wins over every other outcome: even if the app and window match, the
    // text is a secret and must not be pasted into a password box. Diverts to a concealed clipboard copy.
    if captured.isSecureField || current.isSecureField {
        return .clipboardFallback(reason: .secureField)
    }
    guard let capturedBundle = captured.bundleId else {
        return .clipboardFallback(reason: .unknownTarget)
    }
    guard current.bundleId == capturedBundle else {
        return .clipboardFallback(reason: .appChanged)
    }
    if let capturedWindow = captured.focusedWindowId,
       let currentWindow = current.focusedWindowId,
       capturedWindow != currentWindow {
        return .clipboardFallback(reason: .focusChanged)
    }
    return .insert
}

public enum InsertionAction: Equatable, Sendable {
    case paste
    case ax
    case type
    case clipboard
}

// The concrete actuation: the focus-race safety decision is authoritative — a clipboardFallback
// always wins over the mode's preferred method, so a moved target diverts to the clipboard even
// when the mode asks for AX-insert or typing. Only a verified .insert honors mode.insertion.
public func insertionAction(decision: InsertionDecision, method: Mode.Insertion) -> InsertionAction {
    guard decision == .insert else { return .clipboard }
    switch method {
    case .paste: return .paste
    case .insert: return .ax
    case .type: return .type
    }
}
