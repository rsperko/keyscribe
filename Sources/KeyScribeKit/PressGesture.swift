public enum PressStyle: String, Sendable {
    case holdOrTap = "hold-or-tap"
    case holdOnly = "hold-only"
    case tapToToggle = "tap-to-toggle"
}

public enum TriggerEdge: Sendable {
    case down, up
}

public enum DictationCommand: Equatable, Sendable {
    case start
    case commit
    case none
}

public struct PressGesture: Sendable {
    public let style: PressStyle
    public let tapThreshold: Double

    private var recording = false
    private var latched = false
    private var downAt: Double?

    public init(style: PressStyle, tapThreshold: Double) {
        self.style = style
        self.tapThreshold = tapThreshold
    }

    public mutating func cancel() {
        recording = false
        latched = false
        downAt = nil
    }

    public mutating func handle(_ edge: TriggerEdge, at time: Double) -> DictationCommand {
        switch style {
        case .holdOnly:
            switch edge {
            case .down: recording = true; return .start
            case .up:
                guard recording else { return .none }
                recording = false
                return .commit
            }

        case .tapToToggle:
            guard edge == .down else { return .none }
            if recording { recording = false; return .commit }
            recording = true
            return .start

        case .holdOrTap:
            switch edge {
            case .down:
                if latched {
                    latched = false
                    recording = false
                    return .commit
                }
                recording = true
                downAt = time
                return .start
            case .up:
                guard recording, !latched, let downAt else { return .none }
                if time - downAt < tapThreshold {
                    latched = true
                    return .none
                }
                recording = false
                self.downAt = nil
                return .commit
            }
        }
    }
}
