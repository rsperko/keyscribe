import Foundation

public enum AgentStatusQuery: Equatable, Sendable {
    case check(AgentAddress?)
    case all

    private static let verb = ["check", "on"]
    private static let thisConversation: Set<String> = AgentAddress.rowNouns.reduce(into: []) { $0.insert("this \($1)") }
    private static let allConversations: Set<String> = AgentAddress.rowNouns.reduce(into: []) { $0.insert("all \($1)s") }
    private static let whoNeedsMe = "who needs me"
    private static let openers: Set<String> = ["please", "hey", "so", "okay", "ok"]

    public static func parse(
        _ transcript: String, names: [String], namesKnown: Bool = true, read: ((String) -> String)? = nil, afterVerb: [String] = []
    ) -> AgentStatusQuery? {
        let words = spoken(transcript)
        let said = words.joined(separator: " ")
        if said == whoNeedsMe { return .all }
        guard words.count > verb.count, Array(words.prefix(verb.count)) == verb else { return nil }
        let subject = words.dropFirst(verb.count).joined(separator: " ")
        if thisConversation.contains(subject) { return .check(nil) }
        if allConversations.contains(subject) { return .all }
        if AgentAddress.exactName(subject, among: names) == nil, let other = AgentAddress.exactName(subject, among: afterVerb) {
            return .check(.name(other, body: ""))
        }
        switch AgentAddress.spokenName(subject, names: names, namesKnown: namesKnown, read: read) {
        case .none: return words.count - verb.count > AgentRename.nameWords ? nil : .check(.unresolved(spoken: subject, body: ""))
        case let address: return .check(address)
        }
    }

    private static func spoken(_ transcript: String) -> [String] {
        let text = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let letters = String(text.map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
        var words = letters.split(separator: " ").map(String.init)
        while let first = words.first, openers.contains(first) { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        return words
    }
}

public enum AgentStatusAnswer {
    public static let questionWordLimit = 25

    public static func question(in prompt: AgentPrompt?) -> String? {
        guard let title = prompt?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let spoken = SpokenResult.spoken(summary: RedactionTokenizer.apply(title, into: Tokenizer()))
        let words = spoken.split(whereSeparator: { $0.isWhitespace }).count
        return words > 0 && words <= questionWordLimit ? spoken : nil
    }

    public static func status(
        handle: String, state: AgentLiveState, connected: Bool, current: Bool, prompt: AgentPrompt?, description: String?
    ) -> String {
        let reported: String? = switch state {
        case .disconnected: nil
        case .idle: "idle"
        case .working: "working"
        case .waitingApproval: "waiting for approval"
        case .waitingQuestion: "waiting for an answer"
        case .userDialog: "with a dialog open"
        }
        let unavailable = "Its current status is unavailable."
        let body: String
        if !connected || state == .disconnected {
            body = (["not connected.", unavailable] + [reported.map { "Last seen \($0)." }].compactMap { $0 }).joined(separator: " ")
        } else if !current, let reported {
            body = "last seen \(reported). \(unavailable)"
        } else {
            body = switch state {
            case .idle, .working, .disconnected: "\(reported ?? "unknown"). No pending input request is reported."
            case .waitingApproval, .waitingQuestion, .userDialog: waitingBody(state, prompt: prompt, description: description)
            }
        }
        return "Status for \(handle): \(body) \(nothingSent)"
    }

    private static let nothingSent = "Nothing sent."

    private static func waitingBody(_ state: AgentLiveState, prompt: AgentPrompt?, description: String?) -> String {
        if let question = question(in: prompt) { return "waiting for your answer to \u{201C}\(question)\u{201D}" + (".?!".contains(question.last ?? ".") ? "" : ".") }
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return sentence(description)
        }
        return switch state {
        case .waitingApproval: "waiting for approval."
        case .waitingQuestion: "waiting for an answer."
        default: "a dialog is open."
        }
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".?!".contains(last) else { return text }
        return text + "."
    }

    public static func hint(handle: String, state: AgentLiveState, connected: Bool, current: Bool) -> String? {
        guard connected, current else { return nil }
        switch state {
        case .waitingApproval, .waitingQuestion, .userDialog: return "Say \u{201C}open \(handle)\u{201D} to see it."
        case .idle, .working, .disconnected: return nil
        }
    }

    private static let counts = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    public static func all(_ handles: [String], complete: Bool) -> String {
        let unchecked = "conversations couldn\u{2019}t be checked"
        let body: String
        if handles.isEmpty {
            body = "no pending input requests are reported" + (complete ? "." : ", but some \(unchecked).")
        } else {
            let count = handles.count < counts.count ? counts[handles.count] : String(handles.count)
            let list = handles.count > 1 ? handles.dropLast().joined(separator: ", ") + " and " + handles[handles.count - 1] : handles[0]
            body = "\(count) \(handles.count == 1 ? "needs" : "need") you: \(list)." + (complete ? "" : " Some \(unchecked).")
        }
        return "Status for all conversations: \(body) \(nothingSent)"
    }
}
