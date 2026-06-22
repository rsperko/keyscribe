public struct TargetSnapshot: Equatable, Sendable {
    public var bundleId: String?
    public var focusedElementId: String?

    public init(bundleId: String?, focusedElementId: String? = nil) {
        self.bundleId = bundleId
        self.focusedElementId = focusedElementId
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
}

public enum InsertionDecision: Equatable, Sendable {
    case insert
    case clipboardFallback(reason: FallbackReason)
}

public func decideInsertion(captured: TargetSnapshot, current: TargetSnapshot) -> InsertionDecision {
    guard let capturedBundle = captured.bundleId else {
        return .clipboardFallback(reason: .unknownTarget)
    }
    guard current.bundleId == capturedBundle else {
        return .clipboardFallback(reason: .appChanged)
    }
    if let capturedField = captured.focusedElementId,
       let currentField = current.focusedElementId,
       capturedField != currentField {
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
