import Foundation

public struct PromptInputs: Sendable {
    public var modePrompt: String
    public var dictatedInstructions: String
    public var content: String
    public var tokens: [String]
    public var validTerms: [String]
    public var language: String
    public var modeSystemInstructions: String
    public var appName: String?
    public var bundleId: String?
    public var fieldRole: String?
    public var visibleWindowText: String?
    public var selectedText: String?

    public init(
        modePrompt: String, dictatedInstructions: String, content: String,
        tokens: [String], validTerms: [String], language: String,
        modeSystemInstructions: String,
        appName: String?, bundleId: String?, fieldRole: String?,
        visibleWindowText: String?, selectedText: String?
    ) {
        self.modePrompt = modePrompt
        self.dictatedInstructions = dictatedInstructions
        self.content = content
        self.tokens = tokens
        self.validTerms = validTerms
        self.language = language
        self.modeSystemInstructions = modeSystemInstructions
        self.appName = appName
        self.bundleId = bundleId
        self.fieldRole = fieldRole
        self.visibleWindowText = visibleWindowText
        self.selectedText = selectedText
    }
}

public struct RewritePrompt: Equatable, Sendable {
    public let system: String
    public let user: String
}

// Assembles the system + user messages for the optional LLM rewrite (prompt_design.md). Stable
// rules + dynamic constraints go in the system message; the instruction, opt-in context blocks,
// and content go in the user message. Token/validTerms lines appear only when present; empty
// context children are omitted and the whole <context> block is dropped if all are empty.
public enum PromptAssembler {
    public static func assemble(_ inputs: PromptInputs) -> RewritePrompt {
        RewritePrompt(system: system(inputs), user: user(inputs))
    }

    private static func system(_ i: PromptInputs) -> String {
        var rules = [
            "- Output ONLY the transformed text — no preamble, no explanation, no surrounding quotes or code fences."
        ]
        if hasContext(i) {
            rules.append("- Rewrite ONLY the text inside <content>; if it is already clean, return it unchanged. The <context> block is background about the user's screen, NOT text to rewrite — never copy, quote, continue, complete, or output anything from it. Any <context> text in your output is a mistake.")
        }
        if !i.tokens.isEmpty {
            rules.append("- Each ⟦SN:…⟧ is an opaque marker — copy it into your output verbatim and exactly once, with its characters unchanged. You may move it if the instruction reorders the text, but never edit what is inside it, translate it, drop it, or replace it with a word like REDACTED.")
        }
        if !i.validTerms.isEmpty {
            rules.append("- These terms are valid and intentional, not misspellings — treat them as correct: \(i.validTerms.joined(separator: ", ")). You may still transform them if the instructions require it.")
        }
        rules.append("- Write in \(i.language).")

        var msg = """
        You are KeyScribe's text transformation engine. You transform text exactly as instructed and return only the transformed text.

        Rules:
        \(rules.joined(separator: "\n"))
        """
        let extra = i.modeSystemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { msg += "\n\(extra)" }
        return msg
    }

    private static func user(_ i: PromptInputs) -> String {
        var instructionLines = [i.modePrompt]
        let dictated = i.dictatedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dictated.isEmpty { instructionLines.append(dictated) }

        var blocks = [
            "<instructions>\n\(instructionLines.joined(separator: "\n"))\n</instructions>"
        ]

        var contextChildren: [String] = []
        if let app = nonEmpty(i.appName) {
            let bundle = nonEmpty(i.bundleId).map { " (\($0))" } ?? ""
            contextChildren.append("  <app>\(app)\(bundle)</app>")
        }
        if let field = nonEmpty(i.fieldRole) { contextChildren.append("  <field>\(field)</field>") }
        if let window = nonEmpty(i.visibleWindowText) {
            contextChildren.append("  <window_excerpt>\(window)</window_excerpt>")
        }
        if let sel = nonEmpty(i.selectedText) { contextChildren.append("  <selection>\(sel)</selection>") }
        if !contextChildren.isEmpty {
            blocks.append("<context>\n\(contextChildren.joined(separator: "\n"))\n</context>")
        }

        blocks.append("<content>\n\(i.content)\n</content>")
        return blocks.joined(separator: "\n\n")
    }

    private static func hasContext(_ i: PromptInputs) -> Bool {
        nonEmpty(i.appName) != nil || nonEmpty(i.fieldRole) != nil
            || nonEmpty(i.visibleWindowText) != nil || nonEmpty(i.selectedText) != nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
