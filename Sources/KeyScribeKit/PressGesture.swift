public enum PressStyle: String, Sendable {
    case holdOrTap = "hold-or-tap"
    case holdOnly = "hold-only"
    case tapToToggle = "tap-to-toggle"
    case startOnly = "start"
    case stopOnly = "stop"
    case doubleTap = "double-tap"

    public var title: String {
        switch self {
        case .holdOnly: "Hold to talk"
        case .tapToToggle: "Tap to toggle"
        case .holdOrTap: "Hold to talk; tap to toggle"
        case .startOnly: "Start only"
        case .stopOnly: "Stop only"
        case .doubleTap: "Double-tap to start"
        }
    }

    public var instruction: String {
        switch self {
        case .holdOnly: "Hold the trigger while speaking, then release it to stop."
        case .tapToToggle: "Tap once to start, then tap again to stop."
        case .holdOrTap: "Hold and release, or tap to start and tap again to stop."
        case .startOnly: "Press to start; does nothing while a dictation is in progress."
        case .stopOnly: "Press to stop; does nothing when no dictation is recording."
        case .doubleTap: "Tap twice to start, then once to stop. Escape cancels."
        }
    }

    public struct Invocation: Equatable, Sendable {
        public let lead: String
        public let trail: String

        public func sentence(key: String) -> String { "\(lead) \(key) \(trail)" }
    }

    public var invocation: Invocation {
        switch self {
        case .holdOrTap, .holdOnly: Invocation(lead: "Hold", trail: "and speak")
        case .tapToToggle: Invocation(lead: "Tap", trail: "and speak, then tap it again to stop")
        case .doubleTap: Invocation(lead: "Double-tap", trail: "and speak, then tap it again to stop")
        case .startOnly: Invocation(lead: "Press", trail: "and speak")
        case .stopOnly: Invocation(lead: "Press", trail: "to stop")
        }
    }

    public func supports(_ descriptor: KeyDescriptor) -> Bool {
        guard self == .doubleTap else { return true }
        if case .modifiers(let set) = descriptor { return set.members.count == 1 }
        return false
    }
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
    public static let doubleTapWindow = 0.4

    private var recording = false
    private var latched = false
    private var downAt: Double?
    private var physicallyDown = false
    public var isPhysicallyDown: Bool { physicallyDown }
    private var pressSpent = false
    private var firstTapUpAt: Double?
    private var startedAt: Double?

    public init(style: PressStyle, tapThreshold: Double) {
        self.style = style
        self.tapThreshold = tapThreshold
    }

    public mutating func cancel() {
        recording = false
        latched = false
        downAt = nil
        physicallyDown = false
        pressSpent = false
        firstTapUpAt = nil
        startedAt = nil
    }

    public mutating func interrupt() {
        guard style == .doubleTap else { return }
        physicallyDown = false
        downAt = nil
        firstTapUpAt = nil
    }

    public mutating func handle(_ edge: TriggerEdge, at time: Double) -> DictationCommand {
        switch edge {
        case .down:
            if physicallyDown { return .none }
            physicallyDown = true
        case .up:
            physicallyDown = false
        }
        switch style {
        case .doubleTap:
            return handleDoubleTap(edge, at: time)

        case .startOnly:
            return edge == .down ? .start : .none

        case .stopOnly:
            return edge == .down ? .commit : .none

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

    private mutating func handleDoubleTap(_ edge: TriggerEdge, at time: Double) -> DictationCommand {
        switch edge {
        case .down:
            downAt = time
            pressSpent = recording && startedAt.map { time - $0 < PressGesture.doubleTapWindow } ?? false
            return .none
        case .up:
            guard let pressedAt = downAt else { return .none }
            downAt = nil
            let spent = pressSpent
            pressSpent = false
            if recording {
                guard !spent else { return .none }
                recording = false
                startedAt = nil
                return .commit
            }
            guard !spent, time - pressedAt <= tapThreshold else { firstTapUpAt = nil; return .none }
            if let upAt = firstTapUpAt, pressedAt - upAt <= PressGesture.doubleTapWindow {
                firstTapUpAt = nil
                recording = true
                startedAt = time
                return .start
            }
            firstTapUpAt = time
            return .none
        }
    }
}
