import Foundation

public enum AgentStatusQuery: Equatable, Sendable {
    case waiting(AgentAddress?)
    case moreThanAQuestion(AgentAddress)
    case whoNeedsMe

    private static let pronouns: Set<String> = ["you", "it", "he", "she", "they"]
    private static let openers: Set<String> = ["please", "hey", "so", "okay", "ok"]
    private static let contractions = [("what's", "what is"), ("who's", "who is"), ("it's", "it is")]
    private static let fromMe = "(?: from me| for me| on me)?"
    private static let now = "(?: right now| now)?"
    private static let still = "(?: currently| still)?"
    private static let waits = "(?:waiting (?:for|on)|blocked on|stuck on)"
    private static let itWaits = "(?:(?:it|he|she|they) (?:is|are)|(?:is|are) (?:it|he|she|they))\(still) \(waits)"
    private static let itNeeds = "(?:it|he|she|they) (?:needs|need|wants|want)"
    private static let waitingSubjects = [
        "^what (?:is|are) (.+?)\(still) \(waits)\(fromMe)\(now)$",
        "^what (?:does|do) (.+?)\(still) (?:need|want)\(fromMe)\(now)$",
        "^(?:does|do) (.+?)\(still) need anything\(fromMe)\(now)$",
        "^ask (.+?) what \(itWaits)\(fromMe)\(now)$",
        "^ask (.+?) what \(itNeeds)\(fromMe)\(now)$",
        "^(?:is|are) (.+?)\(still) waiting\(fromMe)\(now)$",
        "^why (?:is|are) (.+?)\(still) (?:waiting|stuck|blocked)\(now)$",
        "^what is blocking (.+?)\(now)$",
    ]
    private static let longerQuestions = [
        "^what (?:is|are) (.+?)\(still) \(waits) .+$",
        "^what (?:does|do) (.+?)\(still) (?:need|want) .+$",
        "^(?:does|do) (.+?)\(still) need anything .+$",
        "^(?:is|are) (.+?)\(still) waiting (?:for|on) .+$",
        "^why (?:is|are) (.+?)\(still) (?:waiting|stuck|blocked) .+$",
        "^what is blocking (.+?) .+$",
    ]
    private static let whoNeedsMeForms = [
        "^who (?:needs|need) me\(now)$",
        "^who is (?:waiting|blocked|stuck)\(fromMe)\(now)$",
        "^is (?:anyone|anybody) waiting\(fromMe)\(now)$",
        "^what (?:is|are) (?:everyone|everybody) waiting (?:for|on)\(now)$",
        "^which (?:conversations|sessions) (?:are|is) waiting\(fromMe)\(now)$",
    ]

    public static func parse(
        _ transcript: String, names: [String], namesKnown: Bool = true, read: ((String) -> String)? = nil, afterVerb: [String] = []
    ) -> AgentStatusQuery? {
        let said = spoken(transcript)
        guard !said.isEmpty else { return nil }
        if whoNeedsMeForms.contains(where: { match($0, said) != nil }) { return .whoNeedsMe }
        func conversation(_ subject: String) -> AgentAddress? {
            if AgentAddress.exactName(subject, among: names) == nil, let other = AgentAddress.exactName(subject, among: afterVerb) {
                return .name(other, body: "")
            }
            switch AgentAddress.spokenName(subject, names: names, namesKnown: namesKnown, read: read) {
            case .none: return nil
            case let address: return address
            }
        }
        if let subject = waitingSubjects.lazy.compactMap({ match($0, said) }).first {
            if pronouns.contains(subject) { return .waiting(nil) }
            if let address = conversation(subject) { return .waiting(address) }
        }
        guard let subject = longerQuestions.lazy.compactMap({ match($0, said) }).first, !pronouns.contains(subject) else { return nil }
        return conversation(subject).map { .moreThanAQuestion($0) }
    }

    private static func spoken(_ transcript: String) -> String {
        var text = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for (short, long) in contractions { text = text.replacingOccurrences(of: short, with: long) }
        let letters = String(text.map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
        var words = letters.split(separator: " ").map(String.init)
        while let first = words.first, openers.contains(first) { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let regex = RegexCache.regex(pattern, options: []),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        guard found.numberOfRanges > 1, let range = Range(found.range(at: 1), in: text) else { return "" }
        return String(text[range])
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

    public static func waiting(
        handle: String, state: AgentLiveState, connected: Bool, current: Bool, prompt: AgentPrompt?, description: String?
    ) -> String {
        let seen: String? = switch state {
        case .disconnected: nil
        case .idle: "ready"
        case .working: "working"
        case .waitingApproval: "waiting for approval"
        case .waitingQuestion: "waiting for an answer"
        case .userDialog: "with a dialog open"
        }
        guard connected, state != .disconnected else {
            return "\(handle) isn\u{2019}t connected." + (seen.map { " Last seen \($0)." } ?? "")
        }
        if !current, let seen {
            return "\(handle) was last seen \(seen). I couldn\u{2019}t check its current status."
        }
        switch state {
        case .idle: return "\(handle) is ready for another message."
        case .working: return "\(handle) is working. No request for your input is currently reported."
        case .disconnected: return "\(handle) isn\u{2019}t connected."
        case .waitingApproval, .waitingQuestion, .userDialog:
            if let question = question(in: prompt) { return "\(handle) asks: \(question)" }
            if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                return SpokenResult.prefaced(description, name: handle)
            }
            return switch state {
            case .waitingApproval: "\(handle) is waiting for approval."
            case .waitingQuestion: "\(handle) is waiting for an answer."
            default: "\(handle) has a dialog open."
            }
        }
    }

    public static func hint(handle: String, state: AgentLiveState, connected: Bool, current: Bool) -> String? {
        guard connected, current else { return nil }
        switch state {
        case .waitingApproval, .waitingQuestion, .userDialog: return "Say \u{201C}open \(handle)\u{201D} to see it."
        case .idle, .working, .disconnected: return nil
        }
    }

    private static let counts = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    public static func whoNeedsMe(_ handles: [String], complete: Bool) -> String {
        let unchecked = complete ? "" : " I couldn\u{2019}t check every conversation."
        guard !handles.isEmpty else {
            return complete ? "No conversation needs you." : "No confirmed requests for your input." + unchecked
        }
        let count = handles.count < counts.count ? counts[handles.count] : String(handles.count)
        let list = handles.count > 1 ? handles.dropLast().joined(separator: ", ") + " and " + handles[handles.count - 1] : handles[0]
        let noun = handles.count == 1 ? "conversation needs" : "conversations need"
        return "\(count.prefix(1).uppercased() + count.dropFirst()) \(noun) you: \(list)." + unchecked
    }

}
