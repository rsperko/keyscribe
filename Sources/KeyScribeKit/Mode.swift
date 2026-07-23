import Foundation
import TOMLKit

public struct Mode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var schemaVersion: Int
    public var seedId: String?            // catalog identity if this mode was seeded; nil = user-created
    public var seedVersion: Int?          // catalog version this mode was seeded from
    public var name: String
    public var enabled: Bool
    public var triggerKeys: [TriggerKey]
    public var triggerPhrases: [String]
    public var constraints: [Constraint]
    public var source: Source
    public var output: Output
    public var commands: Commands
    public var dictionary: ModeDictionary
    public var replacements: ModeReplacements
    public var aiRewrite: AIRewrite?
    public var insertion: Insertion
    public var trailing: Trailing
    public var submit: Submit
    public var clipboardModifier: ClipboardModifier
    public var pasteSettleMs: Int
    public var trimTrailingPunctuation: Bool
    public var excludeFromHistory: Bool

    public enum Source: String, Codable, Sendable { case dictation, selection }
    public enum Output: String, Codable, Sendable {
        case cursor
        case replaceSelection = "replace_selection"
    }
    public enum Insertion: String, Codable, Sendable { case paste, insert, type }

    public enum Trailing: String, Codable, Sendable {
        case none, space, newline
        public func suffix(after finalText: String) -> String {
            switch self {
            case .none: return ""
            case .newline: return "\n"
            case .space: return finalText.last?.isWhitespace == true ? "" : " "
            }
        }
    }

    public enum Submit: String, Codable, Sendable {
        case none
        case `return` = "return"
        case shiftReturn = "shift_return"
        case cmdReturn = "cmd_return"
    }

    public enum ClipboardModifier: String, Codable, Sendable {
        case command, control
    }

    public struct TriggerKey: Codable, Equatable, Sendable {
        public var key: String
        public var pressStyle: String
        public var tapThresholdMs: Int
        enum CodingKeys: String, CodingKey { case key; case pressStyle = "press_style"; case tapThresholdMs = "tap_threshold_ms" }
        public init(key: String, pressStyle: String = "hold-or-tap", tapThresholdMs: Int = 250) {
            self.key = key
            self.pressStyle = pressStyle
            self.tapThresholdMs = tapThresholdMs
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            pressStyle = try c.decodeIfPresent(String.self, forKey: .pressStyle) ?? "hold-or-tap"
            tapThresholdMs = try c.decodeIfPresent(Int.self, forKey: .tapThresholdMs) ?? 250
        }
    }

    public struct Constraint: Codable, Equatable, Sendable {
        public var bundleId: String?
        public var bundlePrefix: String?
        public var urlPattern: String?
        public var windowTitle: String?
        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case bundlePrefix = "bundle_prefix"
            case urlPattern = "url_pattern"
            case windowTitle = "window_title"
        }
        public init(
            bundleId: String? = nil, bundlePrefix: String? = nil,
            urlPattern: String? = nil, windowTitle: String? = nil
        ) {
            self.bundleId = bundleId
            self.bundlePrefix = bundlePrefix
            self.urlPattern = urlPattern
            self.windowTitle = windowTitle
        }
    }

    public struct Commands: Codable, Equatable, Sendable {
        public var liveEdits: Bool
        public var privacy: Bool
        public var numbers: Bool
        enum CodingKeys: String, CodingKey {
            case liveEdits = "live_edits"; case privacy
            case numbers
        }
        public init(
            liveEdits: Bool = false, privacy: Bool = false,
            numbers: Bool = false
        ) {
            self.liveEdits = liveEdits
            self.privacy = privacy
            self.numbers = numbers
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            liveEdits = try c.decodeIfPresent(Bool.self, forKey: .liveEdits) ?? false
            privacy = try c.decodeIfPresent(Bool.self, forKey: .privacy) ?? false
            numbers = try c.decodeIfPresent(Bool.self, forKey: .numbers) ?? false
        }
    }

    public struct ModeDictionary: Codable, Equatable, Sendable {
        public var includeGlobal: Bool
        public var words: [String]
        enum CodingKeys: String, CodingKey { case includeGlobal = "include_global"; case words }
        public init(includeGlobal: Bool = true, words: [String] = []) {
            self.includeGlobal = includeGlobal
            self.words = words
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeGlobal = try c.decodeIfPresent(Bool.self, forKey: .includeGlobal) ?? true
            words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        }
    }

    public struct ModeReplacements: Codable, Equatable, Sendable {
        public var includeGlobal: Bool
        public var rules: [ReplacementsSet.Rule]
        enum CodingKeys: String, CodingKey { case includeGlobal = "include_global"; case rules }
        public init(includeGlobal: Bool = true, rules: [ReplacementsSet.Rule] = []) {
            self.includeGlobal = includeGlobal
            self.rules = rules
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeGlobal = try c.decodeIfPresent(Bool.self, forKey: .includeGlobal) ?? true
            rules = try c.decodeIfPresent([ReplacementsSet.Rule].self, forKey: .rules) ?? []
        }
        public func toRules() -> [ReplacementRule] { rules.toReplacementRules() }
    }

    public struct ContextOptIn: Codable, Equatable, Sendable {
        public var app: Bool
        public var precedingText: Bool
        enum CodingKeys: String, CodingKey {
            case app; case precedingText = "preceding_text"
        }
        public init(app: Bool = false, precedingText: Bool = false) {
            self.app = app
            self.precedingText = precedingText
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = try c.decodeIfPresent(Bool.self, forKey: .app) ?? false
            precedingText = try c.decodeIfPresent(Bool.self, forKey: .precedingText) ?? false
        }
    }

    public struct AIRewrite: Codable, Equatable, Sendable {
        public var connection: String
        public var prompt: String
        public var fragments: [String]
        public var context: ContextOptIn
        enum CodingKeys: String, CodingKey { case connection, prompt, fragments, context }
        public init(connection: String, prompt: String, fragments: [String] = [], context: ContextOptIn = .init()) {
            self.connection = connection
            self.prompt = prompt
            self.fragments = fragments
            self.context = context
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            connection = try c.decode(String.self, forKey: .connection)
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
            fragments = try c.decodeIfPresent([String].self, forKey: .fragments) ?? []
            if let bad = fragments.first(where: { !FragmentStore.isValidID($0) }) {
                throw ConfigError.invalid("ai_rewrite.fragments has an invalid instruction id '\(bad)'")
            }
            context = try c.decodeIfPresent(ContextOptIn.self, forKey: .context) ?? .init()
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case seedId = "seed_id"
        case seedVersion = "seed_version"
        case name, enabled
        case triggerKeys = "trigger_keys"
        case triggerPhrases = "trigger_phrases"
        case constraints, source, output, commands, dictionary, replacements
        case aiRewrite = "ai_rewrite"
        case insertion, trailing, submit
        case clipboardModifier = "clipboard_modifier"
        case pasteSettleMs = "paste_settle_ms"
        case trimTrailingPunctuation = "trim_trailing_punctuation"
        case excludeFromHistory = "exclude_from_history"
    }

    public init(id: String, name: String, schemaVersion: Int = 1) {
        self.id = id
        self.schemaVersion = schemaVersion
        seedId = nil
        seedVersion = nil
        self.name = name
        enabled = true
        triggerKeys = []
        triggerPhrases = []
        constraints = []
        source = .dictation
        output = .cursor
        commands = .init()
        dictionary = .init()
        replacements = .init()
        aiRewrite = nil
        insertion = .paste
        trailing = .space
        submit = .none
        clipboardModifier = .command
        pasteSettleMs = 0
        trimTrailingPunctuation = false
        excludeFromHistory = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ""
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        seedId = try c.decodeIfPresent(String.self, forKey: .seedId)
        seedVersion = try c.decodeIfPresent(Int.self, forKey: .seedVersion)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        triggerKeys = try c.decodeIfPresent([TriggerKey].self, forKey: .triggerKeys) ?? []
        triggerPhrases = try c.decodeIfPresent([String].self, forKey: .triggerPhrases) ?? []
        constraints = try c.decodeIfPresent([Constraint].self, forKey: .constraints) ?? []
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .dictation
        output = try c.decodeIfPresent(Output.self, forKey: .output) ?? .cursor
        commands = try c.decodeIfPresent(Commands.self, forKey: .commands) ?? .init()
        dictionary = try c.decodeIfPresent(ModeDictionary.self, forKey: .dictionary) ?? .init()
        replacements = try c.decodeIfPresent(ModeReplacements.self, forKey: .replacements) ?? .init()
        aiRewrite = try c.decodeIfPresent(AIRewrite.self, forKey: .aiRewrite)
        insertion = try c.decodeIfPresent(Insertion.self, forKey: .insertion) ?? .paste
        trailing = try c.decodeIfPresent(Trailing.self, forKey: .trailing) ?? .none
        submit = try c.decodeIfPresent(Submit.self, forKey: .submit) ?? .none
        clipboardModifier = try c.decodeIfPresent(ClipboardModifier.self, forKey: .clipboardModifier) ?? .command
        pasteSettleMs = try c.decodeIfPresent(Int.self, forKey: .pasteSettleMs) ?? 0
        trimTrailingPunctuation = try c.decodeIfPresent(Bool.self, forKey: .trimTrailingPunctuation) ?? false
        excludeFromHistory = try c.decodeIfPresent(Bool.self, forKey: .excludeFromHistory) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(seedId, forKey: .seedId)
        try c.encodeIfPresent(seedVersion, forKey: .seedVersion)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        if !triggerKeys.isEmpty { try c.encode(triggerKeys, forKey: .triggerKeys) }
        if !triggerPhrases.isEmpty { try c.encode(triggerPhrases, forKey: .triggerPhrases) }
        if !constraints.isEmpty { try c.encode(constraints, forKey: .constraints) }
        try c.encode(source, forKey: .source)
        try c.encode(output, forKey: .output)
        try c.encode(commands, forKey: .commands)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(replacements, forKey: .replacements)
        try c.encodeIfPresent(aiRewrite, forKey: .aiRewrite)
        try c.encode(insertion, forKey: .insertion)
        if trailing != .none { try c.encode(trailing, forKey: .trailing) }
        if submit != .none { try c.encode(submit, forKey: .submit) }
        if clipboardModifier != .command { try c.encode(clipboardModifier, forKey: .clipboardModifier) }
        if pasteSettleMs != 0 { try c.encode(pasteSettleMs, forKey: .pasteSettleMs) }
        if trimTrailingPunctuation { try c.encode(trimTrailingPunctuation, forKey: .trimTrailingPunctuation) }
        try c.encode(excludeFromHistory, forKey: .excludeFromHistory)
    }

    public static let systemIdPrefix = "_"
    public static let directId = "_direct"
    public var isSystem: Bool { id == Mode.directId }

    public static var direct: Mode {
        var mode = Mode(id: directId, name: "Plain Dictation")
        mode.commands = Commands(liveEdits: true)
        mode.dictionary = ModeDictionary(includeGlobal: true, words: [])
        mode.replacements = ModeReplacements(includeGlobal: true, rules: [])
        mode.aiRewrite = nil
        return mode
    }

    public func systemNormalized() -> Mode {
        guard id == Mode.directId else { return self }
        var mode = Mode.direct
        mode.triggerKeys = triggerKeys
        mode.insertion = insertion
        mode.trailing = trailing
        mode.submit = submit
        mode.clipboardModifier = clipboardModifier
        mode.pasteSettleMs = pasteSettleMs
        mode.commands.liveEdits = commands.liveEdits
        mode.excludeFromHistory = excludeFromHistory
        return mode
    }

    public func localOnlyForSecureField() -> Mode {
        var mode = self
        mode.aiRewrite = nil
        mode.commands.privacy = true
        return mode
    }

    public var effectiveContext: ContextOptIn {
        if commands.privacy { return ContextOptIn() }
        return aiRewrite?.context ?? ContextOptIn()
    }

    public var effectiveContextCategories: [String] {
        let context = effectiveContext
        var categories: [String] = []
        if context.app { categories.append("app") }
        if context.precedingText { categories.append("preceding text") }
        return categories
    }

    public var invalidRoutingPatternFields: [String] {
        var fields: [String] = []
        for phrase in triggerPhrases {
            if RegexCache.routingRegex(phrase, options: [.caseInsensitive]) == nil {
                if !fields.contains("trigger_phrases") { fields.append("trigger_phrases") }
            }
        }
        for (index, constraint) in constraints.enumerated() {
            if let pattern = constraint.urlPattern {
                if RegexCache.routingRegex(pattern) == nil {
                    let field = "constraints[\(index)].url_pattern"
                    if !fields.contains(field) { fields.append(field) }
                }
            }
            if let pattern = constraint.windowTitle {
                if RegexCache.routingRegex(pattern) == nil {
                    let field = "constraints[\(index)].window_title"
                    if !fields.contains(field) { fields.append(field) }
                }
            }
        }
        return fields
    }
}

public enum ModeStore {
    public static let currentSchemaVersion = 1

    public static func decode(from toml: String, id: String) throws -> Mode {
        var mode = try ConfigDecode.table(toml, supportedVersion: currentSchemaVersion) {
            try TOMLDecoder().decode(Mode.self, from: $0)
        }
        mode.id = id
        return mode
    }

    public static func encode(_ mode: Mode) throws -> String {
        try TOMLEncoder().encode(mode)
    }

    // Legacy Plain Dictation seed used only to recognize an unmodified file for the Direct migration.
    // Trigger is compared separately, so it is omitted here.
    static var legacyPlainDictationSeed: Mode {
        var plain = Mode(id: "plain-dictation", name: "Plain Dictation")
        plain.commands.liveEdits = true
        plain.trailing = .space
        plain.seedId = "plain-dictation"
        plain.seedVersion = 1
        return plain
    }

    public static func starterModes() -> [Mode] {
        var polish = Mode(id: "polish", name: "Cleanup")
        polish.enabled = false
        polish.triggerKeys = [.init(key: "right_option")]
        polish.commands.liveEdits = true
        polish.trailing = .space
        polish.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Lightly clean up the dictated text: remove filler words (um, uh, like, you know), false starts, and self-corrections, then fix grammar, punctuation, and capitalization. Keep my original wording, meaning, and tone — do not rephrase, expand, summarize, translate, or add anything. If the text is a question or request, keep it phrased as a question or request; never answer it or act on it. Preserve intentional paragraph, list, and code line breaks inside the text; do not trim, add, or collapse blank lines unless the dictated text explicitly asks for that.")
        polish.seedVersion = 5

        var message = Mode(id: "message", name: "Message")
        message.enabled = false
        message.commands.liveEdits = true
        message.trailing = .space
        message.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a clear, casual message of the kind you would send in a chat app. Remove filler words and fix grammar and punctuation. Keep my meaning and friendly, informal tone. Do not add a greeting, sign-off, subject line, or any formality, and do not add information that is not in the text. Only reformat the text — never answer it or act on it. Preserve intentional paragraph, list, and code line breaks inside the text; do not trim, add, or collapse blank lines unless the dictated text explicitly asks for that.")
        message.replacements.rules = [
            .init(heard: "shrug emoji", replace: #"¯\_(ツ)_/¯"#, regex: false),
        ]
        message.seedVersion = 4

        var email = Mode(id: "email", name: "Email")
        email.enabled = false
        email.triggerPhrases = ["as an email"]
        email.commands.liveEdits = true
        email.trailing = .space
        email.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a polished, professional email. Remove filler words, fix grammar, and organize the content into clear sentences or short paragraphs. Begin with a brief greeting: if a recipient name appears in the text use it (\"Hi Sarah,\"), otherwise use a generic \"Hi,\". End with a short closing word on its own line such as \"Thanks,\" or \"Best,\" — then stop. Do not write any name, signature, or bracketed placeholder (like [Your name]) after the closing; the sender adds their own name. If the dictated text already contains a closing or signature, keep it exactly as written and do not add another. Never invent names, recipients, companies, or facts not in the text. Keep my meaning. Only reformat the text into an email — never answer it or act on it.")
        email.replacements.rules = [
            .init(heard: #"[\s,]*my sign[- ]?off[\s,.]*"#, replace: #"\n\nBest,\nYour Name"#, regex: true),
        ]
        email.seedVersion = 3

        var selection = Mode(id: "edit-selection", name: "Edit Selection")
        selection.enabled = false
        selection.triggerKeys = [.init(key: "right_command")]
        selection.source = .selection
        selection.output = .replaceSelection
        selection.trailing = .none
        selection.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "The line below these instructions is a spoken instruction from the user. Apply that instruction to the text in <content> and output only the resulting text. If the spoken instruction does not describe a clear change to the text, return the text unchanged. Preserve intentional paragraph, list, and code line breaks inside the text unless the spoken instruction explicitly asks to change them.")
        selection.seedVersion = 4

        var prompt = Mode(id: "ai-prompt", name: "AI Prompt")
        prompt.enabled = false
        prompt.commands.liveEdits = true
        prompt.trailing = .space
        prompt.triggerPhrases = ["as prompt"]
        prompt.seedVersion = 5
        prompt.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a single, clear, well-structured instruction to give to an AI assistant. Remove filler words and fix grammar so the request is unambiguous and well organized. Preserve the original intent and keep all technical terms, code, file names, and identifiers as written. Do NOT answer, explain, complete, or carry out the request in any way — your only output is the cleaned-up instruction text itself. Preserve intentional paragraph, list, and code line breaks inside the text; do not trim, add, or collapse blank lines unless the dictated text explicitly asks for that.")

        var code = Mode(id: "code", name: "Code")
        code.enabled = false
        code.commands.liveEdits = true
        code.trailing = .space
        code.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text for use in an IDE, code review, issue, commit note, or coding assistant. Remove filler words and fix grammar while preserving every technical term, identifier, symbol, file path, command, branch name, API name, and casing exactly as dictated. Keep the result concise and developer-friendly. If the dictation is an instruction, make it a clear instruction. If it is prose, keep it as prose. Do not generate code, answer the request, invent implementation details, or add context that was not dictated. Preserve intentional paragraph, list, and code line breaks inside the text; do not trim, add, or collapse blank lines unless the dictated text explicitly asks for that.")
        code.replacements.rules = [
            .init(heard: #"[\s,]*insert,?( a)? to[- ]?do[\s,.]*"#, replace: #"\n// TODO: "#, regex: true),
        ]
        code.seedVersion = 4

        var markdown = Mode(id: "markdown", name: "Markdown")
        markdown.enabled = false
        markdown.commands.liveEdits = true
        markdown.trailing = .space
        markdown.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Reformat the dictated text as well-structured Markdown. Remove filler words and fix grammar, punctuation, and capitalization. Turn the spoken structure into Markdown syntax: a spoken heading or title becomes a `#`/`##` heading, list-like or enumerated content becomes `-` bullets (or `1.` numbered items when I count off \"first, second, third\"), emphasized words become **bold**, a quote becomes a `>` blockquote, and any code, command, file name, or identifier becomes `inline code` — or a fenced ``` block when I dictate several lines of code. The text may already contain Markdown syntax — bold or italic markers, backtick fences, task-list checkboxes, horizontal rules — keep it exactly where it is and do not double it up. Keep my wording and meaning: do not rephrase, expand, summarize, or add content, and do not invent a title or headings I did not imply. Output the raw Markdown source itself — the literal `#`, `-`, `*`, and backtick characters as plain text. Do NOT wrap your whole answer in a code fence. Never answer the text or act on it; only reformat it. Preserve intentional paragraph, list, and code line breaks inside the text; do not trim, add, or collapse blank lines unless the dictated text explicitly asks for that.")
        markdown.replacements.rules = [
            .init(heard: #"[\s,]*insert,?( a)? check ?box[\s,.]*"#, replace: #"\n- [ ] "#, regex: true),
            .init(heard: #"[\s,]*insert,?( a)? horizontal rule[\s,.]*"#, replace: #"\n\n---\n\n"#, regex: true),
            .init(heard: #"[\s,]*begin,? code,? (?:block|fence)[\s,.]*"#, replace: #"\n```\n"#, regex: true),
            .init(heard: #"[\s,]*end,? code,? (?:block|fence)[\s,.]*"#, replace: #"\n```\n"#, regex: true),
            .init(heard: #"begin,? bold[\s,.]*"#, replace: "**", regex: true),
            .init(heard: #"[\s,]*end,? bold,?"#, replace: "**", regex: true),
            .init(heard: #"begin,? italic[\s,.]*"#, replace: "*", regex: true),
            .init(heard: #"[\s,]*end,? italic,?"#, replace: "*", regex: true),
        ]
        markdown.seedVersion = 4

        var shell = Mode(id: "shell", name: "Shell")
        shell.enabled = false
        shell.trailing = .none
        shell.trimTrailingPunctuation = true
        shell.commands.numbers = true
        shell.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Convert the dictated text into a single shell command for a Unix shell (zsh or bash on macOS), ready to paste and run at a terminal prompt.\n\nOutput ONLY the command — one line or a pipeline, with no leading $ prompt, no surrounding code fence or backticks, no comments, and no explanation. Never run, answer, or describe the command; if the text is phrased as a question (\"how do I...\", \"what is the command to...\"), output the command that does it, not an answer.\n\nBuild exactly the command described. Do not add flags, paths, redirects, or behavior I did not ask for, and never introduce destructive options (rm -rf, --force, -f, overwriting redirects) unless I explicitly said so. Keep file names, paths, flags, branch names, URLs, and other identifiers exactly as dictated. Quote any argument that contains spaces or shell metacharacters. Write numbers as digits.\n\nMap spoken symbols to shell syntax: \"dash\" to -, \"dash dash\" to --, \"pipe\" to |, \"redirect to\" or \"output to\" to >, \"append to\" to >>, \"and and\" to &&, \"or or\" to ||, \"semicolon\" to ;, \"tilde\" to ~, \"slash\" to /, \"dot\" to ., \"star\" or \"glob\" to *, \"dollar\" to $, \"ampersand\" or \"in the background\" to &.\n\nCorrect common speech-to-text mishearings of command names back to the intended tool: \"sue do\" or \"pseudo\" to sudo, \"see dee\" to cd, \"ellis\" to ls, \"make dir\" to mkdir, \"g it\" to git, \"groep\" to grep, \"vee eye\" to vim, \"ess ess h\" to ssh, \"ceh mod\" to chmod, \"cube control\" or \"coob cuttle\" to kubectl, \"dock er\" to docker, \"home brew\" to brew. Use judgment for similar mishearings, but keep anything that is clearly a file name or identifier as spoken.\n\nExamples:\nlist all files including hidden ones in long format → ls -la\nfind every python file under src and search them for the word token → find src -name '*.py' | xargs grep token\ngit checkout a new branch called fix dash auth → git checkout -b fix-auth\nsee dee into tilde slash projects → cd ~/projects\nshow what is listening on port 8000 → lsof -i :8000\n\nIf the text does not describe a command, return it unchanged.")

        return [polish, message, email, selection, prompt, code, markdown, shell].map {
            var mode = $0
            mode.seedId = mode.id
            mode.seedVersion = mode.seedVersion ?? 1
            return mode
        }
    }

    public static func templates() -> [Mode] {
        let order = ["polish", "message", "email", "markdown", "code", "shell", "ai-prompt", "edit-selection"]
        let byId = Dictionary(starterModes().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byId[$0] }
    }

    public static func templateSummary(for seedId: String) -> String {
        switch seedId {
        case "polish": return "Clean up filler and grammar as you dictate"
        case "message": return "Rewrite as a casual chat message"
        case "email": return "Professional email — end with \"as an email\""
        case "markdown": return "Reformat dictation as Markdown"
        case "code": return "Developer-friendly text for code and commits"
        case "shell": return "Turn a spoken request into a shell command"
        case "ai-prompt": return "Clean prompt for an AI — end with \"as prompt\""
        case "edit-selection": return "Rewrite selected text by voice"
        default: return ""
        }
    }

    public static func templateExample(for seedId: String) -> (heard: String, result: String)? {
        switch seedId {
        case "polish":
            return ("um so i think we should uh ship it monday", "I think we should ship it Monday.")
        case "message":
            return ("tell them the build is green and i'll deploy after lunch", "Build's green — I'll deploy after lunch.")
        case "email":
            return ("thanks for the update i'll review it by friday as an email",
                    "Hi,\n\nThanks for the update. I'll review it by Friday.\n\nBest,")
        case "markdown":
            return ("heading project setup then bullets clone install run", "## Project Setup\n\n- Clone\n- Install\n- Run")
        case "code":
            return ("todo handle the empty input case", "// TODO: handle the empty input case")
        case "shell":
            return ("find every swift file changed today", "find . -name '*.swift' -mtime -1")
        case "ai-prompt":
            return ("draft release notes for the audio fixes as prompt", "Draft release notes for the following audio fixes:")
        case "edit-selection":
            return ("“make this more formal” with text selected", "Your selected text, rewritten in a more formal tone.")
        default:
            return nil
        }
    }

    public struct LoadFailure: Equatable, Sendable {
        public let id: String
        public let message: String
        public let usedLastKnownGood: Bool
    }

    public struct LoadResult: Sendable {
        public let modes: [Mode]
        public let failures: [LoadFailure]
    }

    public static func loadAll(in dir: URL) -> [Mode] {
        load(in: dir, previous: []).modes
    }

    public static func load(in dir: URL, previous: [Mode], lkgDir: URL? = nil) -> LoadResult {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return LoadResult(modes: [], failures: [])
        }
        let prior = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var modes: [Mode] = []
        var failures: [LoadFailure] = []
        for url in files.filter({ $0.pathExtension == "toml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let toml = try String(contentsOf: url, encoding: .utf8)
                let decoded = try decode(from: toml, id: id)
                modes.append(decoded.isSystem ? decoded.systemNormalized() : decoded)
                if let lkgDir { saveLKG(toml, id: id, in: lkgDir) }
            } catch {
                if let lastGood = prior[id] {
                    modes.append(lastGood)
                    failures.append(LoadFailure(id: id, message: "\(error)", usedLastKnownGood: true))
                } else if let lkgDir, let recovered = loadLKG(id: id, in: lkgDir) {
                    modes.append(recovered)
                    failures.append(LoadFailure(id: id, message: "\(error)", usedLastKnownGood: true))
                } else {
                    failures.append(LoadFailure(id: id, message: "\(error)", usedLastKnownGood: false))
                }
            }
        }
        return LoadResult(modes: modes, failures: failures)
    }

    private static func saveLKG(_ toml: String, id: String, in lkgDir: URL) {
        let url = lkgDir.appendingPathComponent("\(id).toml")
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == toml { return }
        try? FileManager.default.createDirectory(at: lkgDir, withIntermediateDirectories: true)
        try? toml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func loadLKG(id: String, in lkgDir: URL) -> Mode? {
        let url = lkgDir.appendingPathComponent("\(id).toml")
        guard let toml = try? String(contentsOf: url, encoding: .utf8),
              let mode = try? decode(from: toml, id: id) else { return nil }
        return mode
    }

    public static func write(_ mode: Mode, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encode(mode).write(to: fileURL(for: mode, in: dir), atomically: true, encoding: .utf8)
    }

    public static func delete(_ mode: Mode, from dir: URL) throws {
        guard !mode.isSystem else { return }
        try FileManager.default.removeItem(at: fileURL(for: mode, in: dir))
    }

    // The Direct file also marks the completed Plain Dictation migration.
    public static func ensureSystemModes(in dir: URL, lkgDir: URL? = nil) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(for: .direct, in: dir)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else {
            try? encode(migratedDirect(in: dir)).write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let resolved: Mode?
        do {
            resolved = try decode(from: current, id: Mode.directId).systemNormalized()
        } catch ConfigError.newerSchemaVersion {
            return
        } catch {
            resolved = lkgDir.flatMap { loadLKG(id: Mode.directId, in: $0) }?.systemNormalized()
        }
        guard let resolved, let encoded = try? encode(resolved), encoded != current else { return }
        try? encoded.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func migratedDirect(in dir: URL) -> Mode {
        var direct = Mode.direct
        let modes = loadAll(in: dir)
        let plainURL = dir.appendingPathComponent("plain-dictation.toml")
        if let plain = modes.first(where: { $0.id == "plain-dictation" }), isStockPlainDictation(plain) {
            direct.triggerKeys = plain.triggerKeys.isEmpty
                ? (fnIsFree(modes) ? [.init(key: "fn")] : [])
                : plain.triggerKeys
            try? FileManager.default.removeItem(at: plainURL)
        } else {
            direct.triggerKeys = fnIsFree(modes) ? [.init(key: "fn")] : []
        }
        return direct.systemNormalized()
    }

    private static func isStockPlainDictation(_ mode: Mode) -> Bool {
        guard mode.id == "plain-dictation", mode.enabled else { return false }
        func shape(_ m: Mode) -> Mode {
            var s = m; s.triggerKeys = []; s.enabled = true; s.aiRewrite?.connection = ""; return s
        }
        return shape(mode) == shape(legacyPlainDictationSeed)
    }

    private static func fnIsFree(_ modes: [Mode]) -> Bool {
        !modes.contains { $0.enabled && $0.triggerKeys.contains { $0.key.lowercased() == "fn" } }
    }

    public static func newID(for name: String, existing: [String]) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        let base = words.map(String.init).joined(separator: "-").isEmpty
            ? "mode"
            : words.map(String.init).joined(separator: "-")
        let used = Set(existing)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    public static func uniqueName(for name: String, existing: [String]) -> String {
        let used = Set(existing)
        var candidate = name
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func fileURL(for mode: Mode, in dir: URL) -> URL {
        dir.appendingPathComponent("\(mode.id).toml")
    }

    public static func recordStarterOffersIfFresh(in dir: URL, ledgerDir: URL? = nil) {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        guard existing.isEmpty, let ledgerDir else { return }
        var ledger = loadLedger(in: ledgerDir) ?? SeedLedger()
        for mode in starterModes() {
            ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: nil)
        }
        saveLedger(ledger, in: ledgerDir)
    }

    public static func recordMaterializedSeed(_ mode: Mode, ledgerDir: URL) {
        guard mode.seedId == mode.id else { return }
        var ledger = loadLedger(in: ledgerDir) ?? SeedLedger()
        ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: seedTemplateFingerprint(mode))
        saveLedger(ledger, in: ledgerDir)
    }
}
