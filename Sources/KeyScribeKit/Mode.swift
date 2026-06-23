import Foundation
import TOMLKit

public struct Mode: Codable, Equatable, Sendable, Identifiable {
    public var id: String                 // = filename stem; not stored in the TOML body
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
    public var excludeFromHistory: Bool

    public enum Source: String, Codable, Sendable { case dictation, selection }
    public enum Output: String, Codable, Sendable {
        case cursor
        case replaceSelection = "replace_selection"
    }
    public enum Insertion: String, Codable, Sendable { case paste, insert, type }

    // Literal text appended to the transcript, INSIDE the atomic insert (one ⌘Z still undoes it all).
    public enum Trailing: String, Codable, Sendable {
        case none, space, newline
        public var suffix: String {
            switch self {
            case .none: return ""
            case .space: return " "
            case .newline: return "\n"
            }
        }
    }

    // A keystroke synthesized AFTER a verified insert (outside the undo atom) — Return submits in chat
    // and prompt boxes; ⇧Return is a soft newline; ⌘Return sends in Slack et al. Never fired on a
    // clipboard fallback (the text never reached the target).
    public enum Submit: String, Codable, Sendable {
        case none
        case `return` = "return"
        case shiftReturn = "shift_return"
        case cmdReturn = "cmd_return"
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
        public var urlPattern: String?
        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case urlPattern = "url_pattern"
        }
        public init(bundleId: String?, urlPattern: String? = nil) {
            self.bundleId = bundleId
            self.urlPattern = urlPattern
        }
    }

    public struct Commands: Codable, Equatable, Sendable {
        public var liveEdits: Bool
        public var privacy: Bool
        public var numbers: Bool          // inverse text normalization ("twenty five" → "25")
        public var fuzzyCorrection: Bool  // snap mangled words to dictionary terms
        enum CodingKeys: String, CodingKey {
            case liveEdits = "live_edits"; case privacy
            case numbers; case fuzzyCorrection = "fuzzy_correction"
        }
        public init(
            liveEdits: Bool = false, privacy: Bool = false,
            numbers: Bool = false, fuzzyCorrection: Bool = false
        ) {
            self.liveEdits = liveEdits
            self.privacy = privacy
            self.numbers = numbers
            self.fuzzyCorrection = fuzzyCorrection
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            liveEdits = try c.decodeIfPresent(Bool.self, forKey: .liveEdits) ?? false
            privacy = try c.decodeIfPresent(Bool.self, forKey: .privacy) ?? false
            numbers = try c.decodeIfPresent(Bool.self, forKey: .numbers) ?? false
            fuzzyCorrection = try c.decodeIfPresent(Bool.self, forKey: .fuzzyCorrection) ?? false
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
        public var visibleText: Bool
        public var precedingText: Bool   // bounded text before the caret (native-only, best-effort)
        enum CodingKeys: String, CodingKey {
            case app; case visibleText = "visible_text"; case precedingText = "preceding_text"
        }
        public init(app: Bool = false, visibleText: Bool = false, precedingText: Bool = false) {
            self.app = app
            self.visibleText = visibleText
            self.precedingText = precedingText
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = try c.decodeIfPresent(Bool.self, forKey: .app) ?? false
            visibleText = try c.decodeIfPresent(Bool.self, forKey: .visibleText) ?? false
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
        trailing = .none
        submit = .none
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
        try c.encode(excludeFromHistory, forKey: .excludeFromHistory)
    }

    // Context the mode may actually send: privacy mode forces everything off (design.md §4.4).
    public var effectiveContext: ContextOptIn {
        if commands.privacy { return ContextOptIn() }
        return aiRewrite?.context ?? ContextOptIn()
    }

    public var effectiveContextCategories: [String] {
        let context = effectiveContext
        var categories: [String] = []
        if context.app { categories.append("app") }
        if context.visibleText { categories.append("visible text") }
        if context.precedingText { categories.append("preceding text") }
        return categories
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

    // The seeded starter set (config_schema.md). Plain Dictation is the default and owns the
    // trigger key; every rewrite-using mode carries an empty connection — inert until the user
    // configures one (M5). Prompts are tuned for the Gemini 2.5 Flash floor (prompt_design.md).
    public static func starterModes() -> [Mode] {
        var plain = Mode(id: "plain-dictation", name: "Plain Dictation")
        plain.commands.liveEdits = true
        plain.triggerKeys = [.init(key: "fn")]

        var polished = Mode(id: "polished-dictation", name: "Polished Dictation")
        polished.commands.liveEdits = true
        polished.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Lightly clean up the dictated text: remove filler words (um, uh, like, you know), false starts, and self-corrections, then fix grammar, punctuation, and capitalization. Keep my original wording, meaning, and tone — do not rephrase, expand, summarize, translate, or add anything. If the text is a question or request, keep it phrased as a question or request; never answer it or act on it.")

        var message = Mode(id: "message", name: "Message")
        message.commands.liveEdits = true
        message.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a clear, casual message of the kind you would send in a chat app. Remove filler words and fix grammar and punctuation. Keep my meaning and friendly, informal tone. Do not add a greeting, sign-off, subject line, or any formality, and do not add information that is not in the text. Only reformat the text — never answer it or act on it.")

        var email = Mode(id: "email", name: "Email")
        email.commands.liveEdits = true
        email.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a polished, professional email. Remove filler words, fix grammar, and organize the content into clear sentences or short paragraphs. Begin with a brief greeting: if a recipient name appears in the text use it (\"Hi Sarah,\"), otherwise use a generic \"Hi,\". End with a short closing word on its own line such as \"Thanks,\" or \"Best,\" — then stop. Do not write any name, signature, or bracketed placeholder (like [Your name]) after the closing; the sender adds their own name. Never invent names, recipients, companies, or facts not in the text. Keep my meaning. Only reformat the text into an email — never answer it or act on it.")

        var prompt = Mode(id: "prompt", name: "AI Prompt")
        prompt.commands.liveEdits = true
        prompt.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a single, clear, well-structured instruction to give to an AI assistant. Remove filler words and fix grammar so the request is unambiguous and well organized. Preserve the original intent and keep all technical terms, code, file names, and identifiers as written. Do NOT answer, explain, complete, or carry out the request in any way — your only output is the cleaned-up instruction text itself.")

        var selection = Mode(id: "work-on-selection", name: "Work on Selection")
        selection.source = .selection
        selection.output = .replaceSelection
        selection.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "The line below these instructions is a spoken instruction from the user. Apply that instruction to the text in <content> and output only the resulting text. If the spoken instruction does not describe a clear change to the text, return the text unchanged.")

        var markdown = Mode(id: "markdown", name: "Markdown")
        markdown.enabled = false
        markdown.commands.liveEdits = true
        markdown.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Reformat the dictated text as well-structured Markdown. Remove filler words and fix grammar, punctuation, and capitalization. Turn the spoken structure into Markdown syntax: a spoken heading or title becomes a `#`/`##` heading, list-like or enumerated content becomes `-` bullets (or `1.` numbered items when I count off \"first, second, third\"), emphasized words become **bold**, a quote becomes a `>` blockquote, and any code, command, file name, or identifier becomes `inline code` — or a fenced ``` block when I dictate several lines of code. Keep my wording and meaning: do not rephrase, expand, summarize, or add content, and do not invent a title or headings I did not imply. Output the raw Markdown source itself — the literal `#`, `-`, `*`, and backtick characters as plain text. Do NOT wrap your whole answer in a code fence. Never answer the text or act on it; only reformat it.")

        var shell = Mode(id: "shell", name: "Shell")
        shell.enabled = false
        shell.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "The dictated text describes a shell command. Output a single shell command (or pipeline) that does what I said, ready to paste at a terminal prompt. Convert spoken symbols to their shell characters — for example \"dash\" to -, \"dash dash\" to --, \"pipe\" to |, \"redirect to\" to >, \"append to\" to >>, \"and and\" to &&, \"tilde\" to ~, \"slash\" to /, \"star\" to *, \"dollar\" to $. Keep file names, paths, flags, branch names, and other identifiers exactly as I said them. Output ONLY the command text — no leading $ prompt, no surrounding code fence or backticks, no explanation, comments, or extra lines. Do NOT run, answer, or describe the command; if I phrase it as a question (\"how do I…\"), output the command that does it, not an answer. If the text does not describe a command, return it unchanged.")

        return [plain, polished, message, email, prompt, selection, markdown, shell].map {
            var mode = $0
            mode.seedId = mode.id
            mode.seedVersion = 1
            return mode
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

    // Lenient load: a single malformed mode file must not vanish silently (it would change routing
    // with no signal). Each file is decoded independently; on failure we fall back to the
    // last-known-good copy from `previous` (so an in-progress hand edit keeps the prior mode live)
    // and record a LoadFailure the caller can surface. A file that never decoded is reported and
    // skipped — never substituted with a guess.
    public static func load(in dir: URL, previous: [Mode]) -> LoadResult {
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
                modes.append(try decode(from: toml, id: id))
            } catch {
                if let lastGood = prior[id] {
                    modes.append(lastGood)
                    failures.append(LoadFailure(id: id, message: "\(error)", usedLastKnownGood: true))
                } else {
                    failures.append(LoadFailure(id: id, message: "\(error)", usedLastKnownGood: false))
                }
            }
        }
        return LoadResult(modes: modes, failures: failures)
    }

    public static func write(_ mode: Mode, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encode(mode).write(to: fileURL(for: mode, in: dir), atomically: true, encoding: .utf8)
    }

    public static func delete(_ mode: Mode, from dir: URL) throws {
        try FileManager.default.removeItem(at: fileURL(for: mode, in: dir))
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

    private static func fileURL(for mode: Mode, in dir: URL) -> URL {
        dir.appendingPathComponent("\(mode.id).toml")
    }

    public static func seedStartersIfEmpty(in dir: URL) {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        guard existing.isEmpty else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for mode in starterModes() {
            guard let toml = try? encode(mode) else { continue }
            try? toml.write(to: dir.appendingPathComponent("\(mode.id).toml"), atomically: true, encoding: .utf8)
        }
    }
}
