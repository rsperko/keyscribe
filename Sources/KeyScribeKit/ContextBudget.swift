import Foundation

public enum ContextBudget {
    // Edit-in-place needs output room at least as large as the selection. Estimate input tokens at
    // ~4 chars/token and reserve 25% headroom; never below the connection's floor.
    public static func maxTokens(forSelectionChars chars: Int, floor: Int) -> Int {
        let estimated = Int((Double(chars) / 4.0 * 1.25).rounded())
        return max(floor, estimated)
    }

    public enum VisibleDisposition: Equatable, Sendable {
        case absent
        case kept
        case truncated
        case dropped
    }

    public struct Fit: Equatable, Sendable {
        public let visibleText: String?
        public let visibleDisposition: VisibleDisposition
        public init(visibleText: String?, visibleDisposition: VisibleDisposition) {
            self.visibleText = visibleText
            self.visibleDisposition = visibleDisposition
        }
    }

    public enum FitResult: Equatable, Sendable {
        case ok(Fit)
        case refuse
    }

    public static func fit(mandatoryChars: Int, visibleText: String?,
                           budgetChars: Int, visibleCap: Int) -> FitResult {
        guard mandatoryChars <= budgetChars else { return .refuse }

        let trimmed = visibleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = trimmed, !v.isEmpty else {
            return .ok(Fit(visibleText: nil, visibleDisposition: .absent))
        }

        let allowance = min(visibleCap, budgetChars - mandatoryChars)
        guard allowance > 0 else {
            return .ok(Fit(visibleText: nil, visibleDisposition: .dropped))
        }
        if v.count <= allowance {
            return .ok(Fit(visibleText: v, visibleDisposition: .kept))
        }
        return .ok(Fit(visibleText: String(v.prefix(allowance)), visibleDisposition: .truncated))
    }
}
