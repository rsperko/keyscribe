import Foundation

public enum TakeRouting {
    public struct Route: Equatable, Sendable {
        public let result: PhaseBResult
        public let mode: Mode?
        public let routedByPhrase: Bool
    }

    public static func phaseB(raw: String, eligible: [Mode], context: RoutingContext, pressMode: Mode?) -> Route {
        let result = ModeResolver.resolvePhaseB(eligibleModes: eligible, transcript: raw, context: context)
        let routed = result.routedModeId.flatMap { id in eligible.first { $0.id == id } }
        return Route(result: result, mode: routed ?? pressMode, routedByPhrase: routed != nil)
    }
}
