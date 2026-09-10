import Foundation

public enum EngineSelection: Equatable, Sendable {
    case ok([String])
    case invalid([String])

    public static func resolve(requested: Set<String>?, runnable: [String]) -> EngineSelection {
        guard let requested else { return .ok(runnable) }
        let invalid = requested.subtracting(runnable).sorted()
        guard invalid.isEmpty else { return .invalid(invalid) }
        return .ok(runnable.filter(requested.contains))
    }
}

public enum EngineListState: String, Equatable, Sendable {
    case unavailable, system, installed, missing

    public static func of(systemManaged: Bool, installed: Bool, unavailable: Bool) -> EngineListState {
        if unavailable { return .unavailable }
        if systemManaged { return .system }
        return installed ? .installed : .missing
    }
}
