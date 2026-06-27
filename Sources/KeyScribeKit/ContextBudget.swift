import Foundation

public enum ContextBudget {
    // Edit-in-place needs output room at least as large as the selection. Estimate input tokens at
    // ~4 chars/token and reserve 25% headroom; never below the connection's floor.
    public static func maxTokens(forSelectionChars chars: Int, floor: Int) -> Int {
        let estimated = Int((Double(chars) / 4.0 * 1.25).rounded())
        return max(floor, estimated)
    }
}
