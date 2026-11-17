import Foundation

public enum ToolRunEnd: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut(Int)
    case couldNotStart(String)
}

public enum ToolCheck: Equatable, Sendable {
    case working(String)
    case timedOut(Int)
    case exited(Int32, String)
    case signaled(Int32)
    case noVersion(String)
    case couldNotStart(String)

    public static let shownOutputLimit = 300

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    public static func judge(_ end: ToolRunEnd, output: String) -> ToolCheck {
        switch end {
        case .timedOut(let seconds): return .timedOut(seconds)
        case .signaled(let signal): return .signaled(signal)
        case .couldNotStart(let reason): return .couldNotStart(reason)
        case .exited(let status) where status != 0: return .exited(status, shown(output))
        case .exited: return version(in: output).map(ToolCheck.working) ?? .noVersion(shown(output))
        }
    }

    public static func version(in output: String) -> String? {
        for word in output.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "," }) {
            let numeric = word.hasPrefix("v") ? word.dropFirst() : word[...]
            let core = numeric.prefix { $0.isNumber || $0 == "." }
            guard core.endIndex == numeric.endIndex || numeric[core.endIndex] == "-" || numeric[core.endIndex] == "+" else { continue }
            let parts = core.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return String(core) }
        }
        return nil
    }

    static func shown(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > shownOutputLimit ? String(text.prefix(shownOutputLimit)) + "\u{2026}" : text
    }

    public func describe(command: String) -> String {
        switch self {
        case .working(let version): return "\(command) --version answered \(version)."
        case .timedOut(let seconds): return "\(command) --version did not finish within \(seconds) seconds."
        case .exited(let status, let output):
            return "\(command) --version stopped with exit code \(status)" + (output.isEmpty ? "." : ": \(output)")
        case .signaled(let signal): return "\(command) --version was stopped by signal \(signal)."
        case .noVersion(let output):
            return "\(command) --version printed no version" + (output.isEmpty ? "." : ": \(output)")
        case .couldNotStart(let reason): return "\(command) could not be started: \(reason)"
        }
    }

    var reportLine: String {
        switch self {
        case .working(let version): "works, version \(version)"
        case .timedOut(let seconds): "did not finish within \(seconds) seconds"
        case .exited(let status, let output): "exit code \(status)" + (output.isEmpty ? "" : ": \(output)")
        case .signaled(let signal): "stopped by signal \(signal)"
        case .noVersion(let output): "printed no version" + (output.isEmpty ? "" : ": \(output)")
        case .couldNotStart(let reason): "could not start: \(reason)"
        }
    }
}
