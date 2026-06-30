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
    public var clipboardModifier: ClipboardModifier
    public var trimTrailingPunctuation: Bool
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

    // The modifier used for the synthesized clipboard keystrokes — ⌘C to capture a selection and ⌘V to
    // paste an insert. `command` is the macOS default; `control` targets a guest where ⌃C/⌃V are the
    // paste mechanism (e.g. a Linux/Windows VM with host-clipboard sharing on). It governs both
    // keystrokes, never `submit`. Selection capture in a guest is best-effort: the host pasteboard bump
    // it waits on is driven by the guest's clipboard-sync, not the OS, so its timing is not guaranteed.
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
        public var bundlePrefix: String?     // case-insensitive bundle-id prefix, e.g. "com.jetbrains."
        public var urlPattern: String?
        public var windowTitle: String?      // regex matched against the focused window's title
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
        public var numbers: Bool          // inverse text normalization ("twenty five" → "25")
        // Dictionary recovery (formerly `fuzzy_correction`) moved off the mode. An old mode TOML's
        // `fuzzy_correction` key is simply ignored on decode.
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
        public var precedingText: Bool   // bounded text before the caret (native-only, best-effort)
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
        if trimTrailingPunctuation { try c.encode(trimTrailingPunctuation, forKey: .trimTrailingPunctuation) }
        try c.encode(excludeFromHistory, forKey: .excludeFromHistory)
    }

    // The reserved id namespace (a leading underscore) the slugger can never produce — `newID` builds
    // ids from letters/numbers joined by hyphens, so a user-named mode can never collide with a system
    // mode. The prefix reserves the namespace for *creation*; `isSystem` keys off the exact recognized
    // id, NOT the prefix — so a stray hand-written `_foo.toml` is an ordinary (editable, deletable) mode,
    // not an unguarded pseudo-system one (`systemNormalized` only knows how to lock `_direct`).
    public static let systemIdPrefix = "_"
    public static let directId = "_direct"
    public var isSystem: Bool { id == Mode.directId }

    // The always-available floor (id `_direct`, shown to users as "Plain Dictation"): the mode a trigger
    // falls through to when no eligible mode matches the current context, and the everyday mode that owns
    // Fn by default (design.md §4.3). "Direct"/`_direct` is the internal name; the display name differs.
    // Guaranteed
    // on-device — never an LLM rewrite, never context, never edit-in-place. It still dictates fully: voice
    // edit commands and result handling (trailing/submit/insertion) apply, and it relies on the GLOBAL
    // dictionary/replacements (no vocabulary of its own). History is user-editable — it records per the
    // global History setting by default. A system mode (reserved id) so it can never be deleted,
    // duplicated, or misconfigured to leak.
    public static var direct: Mode {
        var mode = Mode(id: directId, name: "Plain Dictation")
        mode.commands = Commands(liveEdits: true)
        mode.dictionary = ModeDictionary(includeGlobal: true, words: [])
        mode.replacements = ModeReplacements(includeGlobal: true, rules: [])
        mode.aiRewrite = nil
        return mode
    }

    // Enforce a system mode's locked guarantees while preserving the few fields the user may edit, so a
    // hand-edited or stale file can never weaken the floor. Only Direct exists today; any other system id
    // is returned unchanged. Editable: trigger key(s), insertion method, trailing, submit, clipboard
    // modifier, the live-edits toggle, and the exclude-from-history toggle (Direct records per the global
    // History setting unless turned off here). Everything else comes from the canonical locked base.
    public func systemNormalized() -> Mode {
        guard id == Mode.directId else { return self }
        var mode = Mode.direct
        mode.triggerKeys = triggerKeys
        mode.insertion = insertion
        mode.trailing = trailing
        mode.submit = submit
        mode.clipboardModifier = clipboardModifier
        mode.commands.liveEdits = commands.liveEdits
        mode.excludeFromHistory = excludeFromHistory
        return mode
    }

    // A copy of this mode forced fully local for a secure (password) field: no cloud rewrite and no
    // captured context, whatever the mode normally does. The dictated text into a secure field is itself
    // a secret, so even a redacted cloud payload is wrong — the whole transcript is the secret, and
    // redaction protects spans, not the entire input (design.md §4.4). Dropping aiRewrite removes both
    // the LLM call and context capture (context is only gathered when a rewrite runs); privacy is set so
    // any surface reading effectiveContext also reports nothing.
    public func localOnlyForSecureField() -> Mode {
        var mode = self
        mode.aiRewrite = nil
        mode.commands.privacy = true
        return mode
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

    // The original Plain Dictation seed, kept only so the one-time migration can recognize an
    // unmodified copy on disk and replace it with the Direct floor (it is no longer a starter — Direct
    // fills the plain-dictation-on-Fn role). Trigger is compared separately, so it is omitted here.
    static var legacyPlainDictationSeed: Mode {
        var plain = Mode(id: "plain-dictation", name: "Plain Dictation")
        plain.commands.liveEdits = true
        plain.trailing = .space
        plain.seedId = "plain-dictation"
        plain.seedVersion = 1
        return plain
    }

    public static func starterModes() -> [Mode] {
        var polish = Mode(id: "polish", name: "Polish")
        polish.enabled = false
        polish.commands.liveEdits = true
        polish.trailing = .space
        polish.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Lightly clean up the dictated text: remove filler words (um, uh, like, you know), false starts, and self-corrections, then fix grammar, punctuation, and capitalization. Keep my original wording, meaning, and tone — do not rephrase, expand, summarize, translate, or add anything. If the text is a question or request, keep it phrased as a question or request; never answer it or act on it.")

        var message = Mode(id: "message", name: "Message")
        message.enabled = false
        message.commands.liveEdits = true
        message.trailing = .space
        message.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a clear, casual message of the kind you would send in a chat app. Remove filler words and fix grammar and punctuation. Keep my meaning and friendly, informal tone. Do not add a greeting, sign-off, subject line, or any formality, and do not add information that is not in the text. Only reformat the text — never answer it or act on it.")

        var email = Mode(id: "email", name: "Email")
        email.enabled = false
        email.commands.liveEdits = true
        email.trailing = .space
        email.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a polished, professional email. Remove filler words, fix grammar, and organize the content into clear sentences or short paragraphs. Begin with a brief greeting: if a recipient name appears in the text use it (\"Hi Sarah,\"), otherwise use a generic \"Hi,\". End with a short closing word on its own line such as \"Thanks,\" or \"Best,\" — then stop. Do not write any name, signature, or bracketed placeholder (like [Your name]) after the closing; the sender adds their own name. Never invent names, recipients, companies, or facts not in the text. Keep my meaning. Only reformat the text into an email — never answer it or act on it.")

        var selection = Mode(id: "edit-selection", name: "Edit Selection")
        selection.enabled = false
        selection.source = .selection
        selection.output = .replaceSelection
        selection.trailing = .none
        selection.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "The line below these instructions is a spoken instruction from the user. Apply that instruction to the text in <content> and output only the resulting text. If the spoken instruction does not describe a clear change to the text, return the text unchanged.")

        var prompt = Mode(id: "ai-prompt", name: "AI Prompt")
        prompt.enabled = false
        prompt.commands.liveEdits = true
        prompt.trailing = .space
        prompt.triggerPhrases = ["(?i)\\bas a prompt$"]
        prompt.seedVersion = 2
        prompt.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text as a single, clear, well-structured instruction to give to an AI assistant. Remove filler words and fix grammar so the request is unambiguous and well organized. Preserve the original intent and keep all technical terms, code, file names, and identifiers as written. Do NOT answer, explain, complete, or carry out the request in any way — your only output is the cleaned-up instruction text itself.")

        var code = Mode(id: "code", name: "Code")
        code.enabled = false
        code.commands.liveEdits = true
        code.trailing = .space
        code.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Rewrite the dictated text for use in an IDE, code review, issue, commit note, or coding assistant. Remove filler words and fix grammar while preserving every technical term, identifier, symbol, file path, command, branch name, API name, and casing exactly as dictated. Keep the result concise and developer-friendly. If the dictation is an instruction, make it a clear instruction. If it is prose, keep it as prose. Do not generate code, answer the request, invent implementation details, or add context that was not dictated.")

        var markdown = Mode(id: "markdown", name: "Markdown")
        markdown.enabled = false
        markdown.commands.liveEdits = true
        markdown.trailing = .space
        markdown.aiRewrite = Mode.AIRewrite(
            connection: "",
            prompt: "Reformat the dictated text as well-structured Markdown. Remove filler words and fix grammar, punctuation, and capitalization. Turn the spoken structure into Markdown syntax: a spoken heading or title becomes a `#`/`##` heading, list-like or enumerated content becomes `-` bullets (or `1.` numbered items when I count off \"first, second, third\"), emphasized words become **bold**, a quote becomes a `>` blockquote, and any code, command, file name, or identifier becomes `inline code` — or a fenced ``` block when I dictate several lines of code. Honor explicit spoken markers when I use them: \"code fence\" or \"code block\" means wrap the code I dictate next in a fenced ``` block (until I say \"end code\"); \"back tick\" around a word or phrase means make that span `inline code`; \"bold\"/\"end bold\" and \"italic\"/\"end italic\" mark the enclosed words as **bold** or *italic*. Remove the spoken marker words themselves from the output. Keep my wording and meaning: do not rephrase, expand, summarize, or add content, and do not invent a title or headings I did not imply. Output the raw Markdown source itself — the literal `#`, `-`, `*`, and backtick characters as plain text. Do NOT wrap your whole answer in a code fence. Never answer the text or act on it; only reformat it.")

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
    // last-known-good copy — first the in-memory `previous` (an in-progress hand edit keeps the prior
    // mode live), then, when memory has nothing (the file was already malformed AT LAUNCH), the
    // disk-backed copy under `lkgDir`. A file that never decoded and has no LKG is reported and
    // skipped — never substituted with a guess.
    //
    // `lkgDir` is the recovery store: on every clean decode the raw TOML is copied there (only when it
    // changed, so the file system watcher sees at most one redundant reload per genuine edit). It must
    // live OUTSIDE the `dir` being read so a copy is never mistaken for a real mode. Pass nil to disable
    // disk LKG (e.g. one-shot reads).
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
                // A system mode's locked guarantees are enforced at load, so a hand-edited file can never
                // weaken the floor — only its editable fields survive (Mode.systemNormalized).
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

    // Copy a cleanly-decoded mode's raw TOML into the recovery store, skipping the write when the stored
    // copy already matches — so a steady config does no disk churn and the watcher does not see a write.
    private static func saveLKG(_ toml: String, id: String, in lkgDir: URL) {
        let url = lkgDir.appendingPathComponent("\(id).toml")
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == toml { return }
        try? FileManager.default.createDirectory(at: lkgDir, withIntermediateDirectories: true)
        try? toml.write(to: url, atomically: true, encoding: .utf8)
    }

    // The disk-backed last-known-good for `id`, decoded — nil if there is none or it too fails to decode.
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

    // Ensure every system mode (the Direct floor) exists on disk and is normalized to its locked
    // guarantees. Idempotent: a present file is re-normalized (healing any hand-edit) while keeping its
    // editable fields; a missing one is seeded fresh. Writes ONLY when the normalized content differs
    // from disk, so a steady-state install never rewrites the file (no needless FSEvents churn → no
    // spurious config reload / hotkey rebuild on every launch or Settings open). Call after
    // seedStartersIfEmpty.
    //
    // The FIRST time it runs (no `_direct.toml` yet) it also performs the one-time Plain-Dictation→Direct
    // migration: if a stock, enabled `plain-dictation.toml` exists, it is removed and its trigger is
    // carried onto Direct (so Fn — or wherever the user rebound it — keeps doing plain dictation).
    // Anything else (a customized or disabled Plain Dictation, a promoted different mode) is left
    // untouched, and Direct takes Fn only if no enabled mode already holds it. NOTE: `_direct.toml`'s
    // presence IS the migration marker, so this migration runs at most once — see AGENTS.md
    // "Config migrations" before adding another that needs to re-run.
    public static func ensureSystemModes(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(for: .direct, in: dir)
        if let current = try? String(contentsOf: url, encoding: .utf8) {
            let resolved = (try? decode(from: current, id: Mode.directId))?.systemNormalized() ?? .direct
            guard let encoded = try? encode(resolved), encoded != current else { return }
            try? encoded.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        try? encode(migratedDirect(in: dir)).write(to: url, atomically: true, encoding: .utf8)
    }

    // First-run Direct profile + Plain-Dictation migration (see ensureSystemModes).
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

    // A Plain Dictation file the user never meaningfully touched (trigger aside): safe to replace with
    // Direct. Enabled + every template field matches the original seed once the trigger, enabled flag,
    // and AI connection are normalized out.
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

    private static func fileURL(for mode: Mode, in dir: URL) -> URL {
        dir.appendingPathComponent("\(mode.id).toml")
    }

    public static func seedStartersIfEmpty(in dir: URL, ledgerDir: URL? = nil) {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }) ?? []
        guard existing.isEmpty else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var ledger = SeedLedger()
        for mode in starterModes() {
            guard let toml = try? encode(mode) else { continue }
            try? toml.write(to: dir.appendingPathComponent("\(mode.id).toml"), atomically: true, encoding: .utf8)
            ledger.upsert(mode.id, version: mode.seedVersion ?? 1, fingerprint: seedTemplateFingerprint(mode))
        }
        if let ledgerDir { saveLedger(ledger, in: ledgerDir) }
    }
}
