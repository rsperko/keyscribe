import Foundation

// Input for `KeyScribe --rewrite-eval <dir>`: one text-only case per prompt scenario, decoded from
// `cases.json`. A case carries a transcript (with realistic STT errors), the mode prompt (inline or
// via the manifest's shared `prompts` map), the situational inputs the eval variants draw on
// (screen terms, tokens, locale, field affordances, context), and its deterministic checks.
public struct RewriteEvalCase: Sendable, Equatable {
    public let id: String
    public let tags: [String]
    public let modePrompt: String
    public let transcript: String
    public let screenTerms: [String]
    public let tokens: [String]
    public let language: String
    public let locale: String?
    public let fieldSingleLine: Bool?
    public let fieldPlainText: Bool?
    public let appName: String?
    public let precedingText: String?
    public let selectedText: String?
    public let userName: String?
    public let currentDateTime: String?
    public let checks: Checks

    public struct Checks: Sendable, Equatable {
        public var mustContain: [String]
        public var mustNotContain: [String]
        public var regexAbsent: [String]
        public var reference: String?
        public var maxWer: Double?

        public init(
            mustContain: [String] = [], mustNotContain: [String] = [], regexAbsent: [String] = [],
            reference: String? = nil, maxWer: Double? = nil
        ) {
            self.mustContain = mustContain
            self.mustNotContain = mustNotContain
            self.regexAbsent = regexAbsent
            self.reference = reference
            self.maxWer = maxWer
        }
    }

    public init(
        id: String, tags: [String], modePrompt: String, transcript: String,
        screenTerms: [String], tokens: [String], language: String, locale: String?,
        fieldSingleLine: Bool?, fieldPlainText: Bool?,
        appName: String?, precedingText: String?, selectedText: String?, userName: String?,
        currentDateTime: String? = nil, checks: Checks
    ) {
        self.id = id
        self.tags = tags
        self.modePrompt = modePrompt
        self.transcript = transcript
        self.screenTerms = screenTerms
        self.tokens = tokens
        self.language = language
        self.locale = locale
        self.fieldSingleLine = fieldSingleLine
        self.fieldPlainText = fieldPlainText
        self.appName = appName
        self.precedingText = precedingText
        self.selectedText = selectedText
        self.userName = userName
        self.currentDateTime = currentDateTime
        self.checks = checks
    }
}

public enum RewriteEvalManifestError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case unknownPromptId(String, caseId: String)
    case missingPrompt(caseId: String)
    case duplicateCaseId(String)
}

public struct RewriteEvalManifest: Sendable, Equatable {
    public let cases: [RewriteEvalCase]

    public init(cases: [RewriteEvalCase]) {
        self.cases = cases
    }

    public static func load(from url: URL) throws -> RewriteEvalManifest {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> RewriteEvalManifest {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.schemaVersion == 1 else {
            throw RewriteEvalManifestError.unsupportedSchemaVersion(raw.schemaVersion)
        }
        var seen = Set<String>()
        let cases = try raw.cases.map { c -> RewriteEvalCase in
            guard seen.insert(c.id).inserted else {
                throw RewriteEvalManifestError.duplicateCaseId(c.id)
            }
            let prompt: String
            if let inline = c.prompt {
                prompt = inline
            } else if let pid = c.promptId {
                guard let shared = raw.prompts?[pid] else {
                    throw RewriteEvalManifestError.unknownPromptId(pid, caseId: c.id)
                }
                prompt = shared
            } else {
                throw RewriteEvalManifestError.missingPrompt(caseId: c.id)
            }
            return RewriteEvalCase(
                id: c.id, tags: c.tags ?? [], modePrompt: prompt, transcript: c.transcript,
                screenTerms: c.screenTerms ?? [], tokens: c.tokens ?? [],
                language: c.language ?? "English", locale: c.locale,
                fieldSingleLine: c.field?.singleLine, fieldPlainText: c.field?.plainText,
                appName: c.appName, precedingText: c.precedingText,
                selectedText: c.selectedText, userName: c.userName,
                currentDateTime: c.currentDateTime,
                checks: RewriteEvalCase.Checks(
                    mustContain: c.checks?.mustContain ?? [],
                    mustNotContain: c.checks?.mustNotContain ?? [],
                    regexAbsent: c.checks?.regexAbsent ?? [],
                    reference: c.checks?.reference, maxWer: c.checks?.maxWer))
        }
        return RewriteEvalManifest(cases: cases)
    }

    private struct Raw: Decodable {
        let schemaVersion: Int
        let prompts: [String: String]?
        let cases: [RawCase]
    }

    private struct RawCase: Decodable {
        let id: String
        let tags: [String]?
        let prompt: String?
        let promptId: String?
        let transcript: String
        let screenTerms: [String]?
        let tokens: [String]?
        let language: String?
        let locale: String?
        let field: RawField?
        let appName: String?
        let precedingText: String?
        let selectedText: String?
        let userName: String?
        let currentDateTime: String?
        let checks: RawChecks?

        struct RawField: Decodable {
            let singleLine: Bool?
            let plainText: Bool?
        }
        struct RawChecks: Decodable {
            let mustContain: [String]?
            let mustNotContain: [String]?
            let regexAbsent: [String]?
            let reference: String?
            let maxWer: Double?
        }
    }
}
