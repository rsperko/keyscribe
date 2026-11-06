import Foundation

public struct SpokenResultSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var connection: String
    public var prompt: String?
    public var voice: String?

    public static let defaultPrompt = """
    Summarize this reply from a coding agent in one or two short, natural sentences to be read aloud: aim for 15 \
    to 25 words, never more than 40 words. Lead with any failure, unanswered question, or decision waiting on the \
    developer, then what was done or found. Keep any uncertainty, anything unverified, and skipped tests. Plain \
    text only: no markdown, code, file paths, URLs, markup or lists. Output only the words to speak.
    """

    enum CodingKeys: String, CodingKey {
        case enabled, connection, prompt, voice
    }

    public init(enabled: Bool? = nil, connection: String = "", prompt: String? = nil, voice: String? = nil) {
        self.enabled = enabled ?? !connection.isEmpty
        self.connection = connection
        self.prompt = prompt
        self.voice = voice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled),
            connection: try c.decodeIfPresent(String.self, forKey: .connection) ?? "",
            prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
            voice: try c.decodeIfPresent(String.self, forKey: .voice))
    }

    public var isOn: Bool { enabled && !connection.isEmpty }
    public var effectivePrompt: String { prompt ?? Self.defaultPrompt }
}

public enum SpokenResult {
    public static let verbatimWordLimit = 40
    public static let summaryWordLimit = 40
    public static let inputCharacterLimit = 12_000
    private static let tokenNote = "Any ⟦SN:…⟧ token stands for text hidden from you: keep it exactly as written, or leave it out."
    private static let hiddenValue = "a hidden value"

    public enum Plan: Equatable, Sendable {
        case nothing
        case speak(String)
        case summarize(String)
    }

    public static func plan(answer: String, configured: Bool) -> Plan {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        let spoken = spoken(summary: RedactionTokenizer.apply(answer, into: Tokenizer()))
        let words = answer.split(whereSeparator: { $0.isWhitespace }).count
        if words <= verbatimWordLimit && !spoken.isEmpty { return .speak(spoken) }
        return configured ? .summarize(answer) : .speak(finishedBody)
    }

    public static let finishedBody = "Finished."

    public static func fits(_ spoken: String) -> Bool {
        spoken.split(whereSeparator: { $0.isWhitespace }).count <= summaryWordLimit
    }

    public static func shorter(system: String) -> String {
        system + "\n\nYour last answer was too long to read aloud. Answer again in at most \(summaryWordLimit) words, keeping any failure, open question or decision."
    }

    public static func prefaced(_ text: String, name: String) -> String {
        name.isEmpty ? text : "\(name): \(text)"
    }

    public static let unavailableBody = "The spoken summary is unavailable."

    public static func notice(_ attention: AgentAttention) -> String {
        switch attention {
        case .approval: "Waiting for approval."
        case .question: "Waiting for an answer."
        case .disconnected: "Disconnected before it finished."
        case .waiting: "Waiting for you."
        }
    }

    public static func unavailable(names: [String]) -> (name: String, body: String) {
        var named: [String] = []
        for name in names where !name.isEmpty && !named.contains(name) { named.append(name) }
        let list = named.count > 1 ? named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1] : named.first ?? ""
        let several = named.isEmpty ? names.count > 1 : named.count > 1
        return (list, several ? "The spoken summaries are unavailable." : unavailableBody)
    }

    public static func spokenForm(_ text: String) -> String {
        var out = replacing(text, #"(?s)```.*?```"#, with: " code block ")
        out = replacing(out, #"(?s)```.*$"#, with: " code block ")
        out = replacing(out, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
        out = replacing(out, #"https?://[^\s]*[^\s.,;:!?)]"#, with: "a link")
        out = replacing(out, #"(?m)^\s*\|.*$"#, with: "")
        out = replacing(out, #"(?m)^\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)"#, with: "")
        out = replacing(out, #"`([^`]*)`"#, with: "$1")
        out = out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        out = replacing(out, #"\s+"#, with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func bounded(_ text: String, limit: Int = inputCharacterLimit) -> String {
        guard text.count > limit else { return text }
        let separator = "\n[…]\n"
        let head = limit / 3
        let tail = max(0, limit - head - separator.count)
        return String(text.prefix(head)) + separator + String(text.suffix(tail))
    }

    public static func request(answer: String, prompt: String, tokenizer: Tokenizer) -> (system: String, user: String) {
        let user = RedactionTokenizer.apply(bounded(answer), into: tokenizer)
        let system = tokenizer.issuedTokens.isEmpty ? prompt : prompt + "\n\n" + tokenNote
        return (system, user)
    }

    public static let waitingPrompt = """
        A coding agent has paused on a prompt and is waiting for the user. Below are what is known about it: the \
        prompt's kind (select, confirm, input, editor or custom) and title, the tool call that was running and its \
        arguments, and the agent's last words before it asked. The tool call may be unrelated to the prompt; when \
        they disagree, the prompt's title wins. Say in one spoken sentence of at most twenty-five words what it is \
        waiting for, starting with a verb such as "Asks": for a select, what to choose, naming the options when \
        there are only a few; for a confirm, what to allow; for an input or editor, what to type. Use plain words, \
        no markup and no code. Do not guess: if none of this says what it asks, answer only "Waiting for you."
        """
    public static let waitingDetailLimit = 1_000
    public static let waitingSaidLimit = 500

    public static func waitingRequest(_ waiting: AgentPrompt, tokenizer: Tokenizer) -> (system: String, user: String)? {
        let described = [
            ("Prompt", waiting.title), ("Tool", waiting.tool), ("Arguments", waiting.detail.map { bounded($0, limit: waitingDetailLimit) }),
            ("Agent said", waiting.said.map { bounded($0, limit: waitingSaidLimit) }),
        ].compactMap { label, value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }
        guard !described.isEmpty else { return nil }
        let lines = (waiting.kind.map { ["Kind: \($0)"] } ?? []) + described
        return request(answer: lines.joined(separator: "\n"), prompt: waitingPrompt, tokenizer: tokenizer)
    }

    public static func spoken(summary: String) -> String {
        spokenForm(replacing(summary, #"⟦SN:[^⟧]*⟧"#, with: hiddenValue))
    }

    private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = RegexCache.regex(pattern, options: []) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

public enum AgentAttention: Equatable, Sendable {
    case approval, question, disconnected
    case waiting(AgentPrompt)
}
