import Foundation

public struct SpokenResultSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var connection: String
    public var prompt: String?
    public var voice: String?
    public var textOnly: Bool

    public static let defaultPrompt = """
    The text below is an agent's reply to a developer. Tell the developer what they most need to know in one \
    or two short spoken sentences, about 25 words in all. Anything that failed, is unverified, or waits on their \
    answer or decision comes first; otherwise the main result. Leave out everything else, even if that drops \
    several points. When the developer's request is given under "Request:", open with two to five words naming \
    what they asked; the order above still decides what follows. Speak plainly, as to a colleague, and output \
    only what to say.
    """

    enum CodingKeys: String, CodingKey {
        case enabled, connection, prompt, voice
        case textOnly = "text_only"
    }

    public init(
        enabled: Bool = false, connection: String = "", prompt: String? = nil, voice: String? = nil, textOnly: Bool = false
    ) {
        self.enabled = enabled
        self.connection = connection
        self.prompt = prompt
        self.voice = voice
        self.textOnly = textOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            connection: try c.decodeIfPresent(String.self, forKey: .connection) ?? "",
            prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
            voice: try c.decodeIfPresent(String.self, forKey: .voice),
            textOnly: try c.decodeIfPresent(Bool.self, forKey: .textOnly) ?? false)
    }

    public var isOn: Bool { enabled && !connection.isEmpty }
    public var effectivePrompt: String { prompt ?? Self.defaultPrompt }
}

public enum SpokenResult {
    public static let verbatimWordLimit = 40
    public static let runawayWordLimit = 120
    public static let inputCharacterLimit = 12_000
    private static let tokenNote = "Any ⟦SN:…⟧ token stands for text hidden from you: keep it exactly as written, or leave it out."
    private static let hiddenValue = "a hidden value"
    private static let requestNote = """
        The developer's request is under "Request:" and the agent's reply under "Reply:". Summarize the reply; \
        the request only says what it answers.
        """

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
        return configured ? .summarize(answer) : .speak(repliedBody)
    }

    public static let repliedBody = "Replied. Open the conversation for the result."
    public static let noTextBody = "Finished without a written reply. Open the conversation for the result."

    public static func ending(_ reason: String) -> String? {
        switch reason {
        case "answer", "complete", "aborted": nil
        case "error": "Ended with an error."
        case "refusal": "Couldn\u{2019}t complete the request."
        default: repliedBody
        }
    }

    public struct Held: Equatable, Sendable {
        public let text: String
        public let shortened: Bool
        public init(text: String, shortened: Bool) {
            self.text = text
            self.shortened = shortened
        }
    }

    public static func held(_ spoken: String) -> Held {
        let words = spoken.split(whereSeparator: { $0.isWhitespace })
        guard words.count > runawayWordLimit else { return Held(text: spoken, shortened: false) }
        let kept = words.prefix(runawayWordLimit)
        if let end = kept.lastIndex(where: { $0.last.map { ".!?".contains($0) } ?? false }),
           end - kept.startIndex + 1 >= runawayWordLimit / 2 {
            return Held(text: kept[...end].joined(separator: " "), shortened: true)
        }
        return Held(text: kept.joined(separator: " ") + "…", shortened: true)
    }

    public static func prefaced(_ text: String, name: String, cause: Cause? = nil) -> String {
        guard case .sender(let sender) = cause else { return name.isEmpty ? text : "\(name): \(text)" }
        let cue = cue(for: sender)
        return name.isEmpty ? "\(cue.alone): \(text)" : "\(name), \(cue.joined): \(text)"
    }

    public enum Cause: Equatable, Sendable {
        case request(String)
        case sender(AgentTurnInput.Sender)

        public var asked: String? {
            guard case .request(let asked) = self else { return nil }
            return asked
        }
    }

    public static func cause(after input: AgentTurnInput?, asked: String?) -> Cause? {
        guard let input else { return nil }
        let last = input.accepted.map { $0.last?.digest } ?? input.prompt
        if let asked, last == AgentPromptDigest.of(asked) { return .request(asked) }
        return input.from.map(Cause.sender)
    }

    private static func cue(for sender: AgentTurnInput.Sender) -> (joined: String, alone: String) {
        switch sender {
        case .agent: ("answering another agent", "Answering another agent")
        case .task: ("after a background task", "After a background task")
        case .schedule: ("after a scheduled prompt", "After a scheduled prompt")
        case .other: ("answering someone else", "Answering someone else")
        }
    }

    public static let unavailableBody = "No summary of the long reply. Open the conversation for the result."

    public static func notice(_ attention: AgentAttention) -> String {
        switch attention {
        case .approval: "Waiting for approval."
        case .question: "Waiting for an answer."
        case .disconnected: "Disconnected before it finished."
        case .waiting(let prompt):
            switch AgentLiveState.userDialog.named(by: prompt) {
            case .waitingApproval: notice(.approval)
            case .waitingQuestion: notice(.question)
            default: "Waiting for you."
            }
        }
    }

    public static func unavailable(names: [String]) -> (name: String, body: String) {
        var named: [String] = []
        for name in names where !name.isEmpty && !named.contains(name) { named.append(name) }
        let list = named.count > 1 ? named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1] : named.first ?? ""
        let several = named.isEmpty ? names.count > 1 : named.count > 1
        return (list, several ? "No summaries of the long replies. Open the conversations for the results." : unavailableBody)
    }

    public static func spokenForm(_ text: String) -> String {
        var out = replacing(text.replacingOccurrences(of: "\r\n", with: "\n"), #"(?s)```.*?```"#, with: " code block ")
        out = replacing(out, #"(?s)```.*$"#, with: " code block ")
        out = replacing(out, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
        out = replacing(out, #"https?://[^\s]*[^\s.,;:!?)]"#, with: "a link")
        out = replacing(out, #"(?m)^\s*\|.*$"#, with: "")
        out = replacing(out, #"(?m)^(\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+).*[^\s.!?:;,…])[ \t]*$"#, with: "$1.")
        out = replacing(out, #"([^\s.!?:;,…])[ \t]*(?=\n[ \t]*\n)"#, with: "$1.")
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

    public struct Request: Equatable, Sendable {
        public let system: String
        public let user: String
        fileprivate init(system: String, user: String) {
            self.system = system
            self.user = user
        }
    }

    public static let askedCharacterLimit = 1_000

    public static func request(answer: String, asked: String? = nil, prompt: String, tokenizer: Tokenizer) -> Request {
        let reply = RedactionTokenizer.apply(bounded(answer), into: tokenizer)
        let user = asked.map {
            "Request:\n" + RedactionTokenizer.apply(bounded($0, limit: askedCharacterLimit), into: tokenizer) + "\n\nReply:\n" + reply
        } ?? reply
        let shaped = asked == nil || prompt == SpokenResultSettings.defaultPrompt ? prompt : prompt + "\n\n" + requestNote
        let system = tokenizer.issuedTokens.isEmpty ? shaped : shaped + "\n\n" + tokenNote
        return Request(system: system, user: user)
    }

    public static let waitingPrompt = """
        An agent has paused on a prompt and is waiting for the user. Below are what is known about it: the \
        prompt's kind (select, confirm, input, editor or custom) and title, the tool call that was running and its \
        arguments, and the agent's last words before it asked. The tool call may be unrelated to the prompt; when \
        they disagree, the prompt's title wins. Say in one spoken sentence of at most twenty-five words what it is \
        waiting for, starting with a verb such as "Asks": for a select, what to choose, naming the options when \
        there are only a few; for a confirm, what to allow; for an input or editor, what to type. Use plain words, \
        no markup and no code. Do not guess: if none of this says what it asks, answer only "Waiting for you."
        """
    public static let waitingDetailLimit = 1_000
    public static let waitingSaidLimit = 500

    public static func waitingRequest(_ waiting: AgentPrompt, tokenizer: Tokenizer) -> Request? {
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
