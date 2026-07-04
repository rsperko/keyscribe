public struct TargetSnapshot: Equatable, Sendable {
    public var bundleId: String?
    public var focusedWindowId: String?
    // Best-effort secure-field signal; secure dictation is diverted to concealed clipboard delivery.
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

public func insertionAction(decision: InsertionDecision, method: Mode.Insertion) -> InsertionAction {
    guard decision == .insert else { return .clipboard }
    switch method {
    case .paste: return .paste
    case .insert: return .ax
    case .type: return .type
    }
}
