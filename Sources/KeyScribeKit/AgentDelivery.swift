import Foundation

public struct AgentDelivery: Equatable, Sendable {
    public enum Check: Equatable, Sendable {
        case asked
        case answered(AgentDeliveryReport.State)
        case unanswered
    }

    public var handedOff: Date
    public var handedToAgent: Date?
    public var entered: Date?
    public var confirmed: Date?
    public var altered = false
    public var reconnects = 0
    public var doubted: Date?
    public var check: Check?
    public var miss: String?
    public var followedTurn: Date?

    public init(handedOff: Date) {
        self.handedOff = handedOff
    }

    public mutating func absorb(_ report: AgentDeliveryReport) {
        handedToAgent = handedToAgent ?? report.handedAt
        entered = entered ?? report.seenAt
        altered = altered || report.altered
        miss = report.miss ?? miss
    }

    public func describe(agent: String, timeZone: TimeZone = .current) -> String {
        var parts = ["Handed off at \(clock(handedOff, timeZone))"]
        if let handedToAgent { parts.append("\(agent) had it \(after(handedToAgent))") }
        if let entered { parts.append("it entered the conversation \(after(entered))" + (altered ? ", changed on its way in" : "")) }
        if let doubted { parts.append("not confirmed by \(after(doubted))") }
        if let check, let words = Self.words(check, agent: agent) { parts.append(words) }
        if let miss, confirmed == nil {
            parts.append(miss == "other" ? "another message entered the conversation" : "it did not match, for a reason this version does not know")
        }
        if let followedTurn { parts.append("a turn started \(after(followedTurn)), so its reply is followed") }
        if let confirmed { parts.append("confirmed \(after(confirmed))") }
        if reconnects > 0 { parts.append("\(reconnects) reconnect\(reconnects == 1 ? "" : "s") while waiting") }
        return parts.joined(separator: "; ")
    }

    private static func words(_ check: Check, agent: String) -> String? {
        switch check {
        case .asked: nil
        case .unanswered: "a check got no answer"
        case .answered(.holding): "a check found \(agent) still holding it"
        case .answered(.handed): "a check found \(agent) had it but it had not entered the conversation"
        case .answered(.seen): "a check found it in the conversation"
        case .answered(.refused): "a check found \(agent) refused it"
        case .answered(.unknown): "a check found the connector has no record of it"
        }
    }

    private func after(_ date: Date) -> String {
        String(format: "+%.2f s", date.timeIntervalSince(handedOff))
    }

    private func clock(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
