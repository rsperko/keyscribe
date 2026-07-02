import Foundation

public struct PromptInputs: Sendable {
    public var modePrompt: String
    public var dictatedInstructions: String
    public var content: String
    public var tokens: [String]
    public var validTerms: [String]
    // The mode's shared fragment bodies, in order. Rendered as labeled standing style rules inside
    // <instructions> rather than flattened into modePrompt, so the model treats them as overlays the
    // task must satisfy — not part of the (often conservative) cleanup instruction.
    public var styleRules: [String]
    public var language: String
    public var modeSystemInstructions: String
    public var appName: String?
    public var bundleId: String?
    public var fieldRole: String?
    public var selectedText: String?
    public var precedingText: String?

    public init(
        modePrompt: String, dictatedInstructions: String, content: String,
        tokens: [String], validTerms: [String], styleRules: [String] = [], language: String,
        modeSystemInstructions: String,
        appName: String?, bundleId: String?, fieldRole: String?,
        selectedText: String?, precedingText: String? = nil
    ) {
        self.modePrompt = modePrompt
        self.dictatedInstructions = dictatedInstructions
        self.content = content
        self.tokens = tokens
        self.validTerms = validTerms
        self.styleRules = styleRules
        self.language = language
        self.modeSystemInstructions = modeSystemInstructions
        self.appName = appName
        self.bundleId = bundleId
        self.fieldRole = fieldRole
        self.selectedText = selectedText
        self.precedingText = precedingText
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
            "- Output ONLY the transformed text — no preamble, no explanation, no surrounding quotes, code fences, or XML tags.",
            "- Rewrite only the text inside <content>: apply every instruction fully, but make no change an instruction does not call for. Return it unchanged only when the instructions call for no change to already-correct text."
        ]
        if hasContext(i) {
            rules.append("- The <context> block is background about the user's screen, NOT text to rewrite — never copy, quote, continue, complete, or output anything from it. Any <context> text in your output is a mistake.")
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
        var instructionLines: [String] = []
        let mode = i.modePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mode.isEmpty { instructionLines.append(mode) }
        let dictated = i.dictatedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dictated.isEmpty { instructionLines.append(dictated) }

        var instructionBody = instructionLines.joined(separator: "\n")
        // Shared fragments render as a labeled, bulleted section of standing style rules. The lead-in
        // tells the model to apply them even to already-clean text (counters the minimal-change prior
        // inline) and that a style rule wins a conflict with the mode wording above (precedence).
        let styleRules = i.styleRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !styleRules.isEmpty {
            let lead = "Always also apply these style rules, even to otherwise-clean text. Where a style rule conflicts with the wording instruction above, the style rule wins:"
            let bullets = styleRules.map { "- \($0)" }.joined(separator: "\n")
            let section = "\(lead)\n\(bullets)"
            instructionBody = instructionBody.isEmpty ? section : "\(instructionBody)\n\n\(section)"
        }

        var blocks = [
            "<instructions>\n\(instructionBody)\n</instructions>"
        ]

        // Context children carry *untrusted* external text (pre-caret text, the app name). Neutralize
        // any of our block-delimiter tags inside them so a crafted value cannot close
        // its block and inject a fake <instructions> — the validation gate catches dropped tokens, but
        // not a successful injection that yields clean output. Content/instructions are NOT neutralized:
        // content is echoed back, so a zero-width space would leak into the insert.
        var contextChildren: [String] = []
        if let app = nonEmpty(i.appName) {
            let bundle = nonEmpty(i.bundleId).map { " (\(neutralize($0)))" } ?? ""
            contextChildren.append("  <app>\(neutralize(app))\(bundle)</app>")
        }
        if let field = nonEmpty(i.fieldRole) { contextChildren.append("  <field>\(neutralize(field))</field>") }
        if let sel = nonEmpty(i.selectedText) { contextChildren.append("  <selection>\(neutralize(sel))</selection>") }
        if let preceding = nonEmpty(i.precedingText) {
            contextChildren.append("  <preceding_text>\(neutralize(preceding))</preceding_text>")
        }
        if !contextChildren.isEmpty {
            blocks.append("<context>\n\(contextChildren.joined(separator: "\n"))\n</context>")
        }

        blocks.append("<content>\n\(i.content)\n</content>")
        return blocks.joined(separator: "\n\n")
    }

    private static func hasContext(_ i: PromptInputs) -> Bool {
        nonEmpty(i.appName) != nil || nonEmpty(i.fieldRole) != nil
            || nonEmpty(i.selectedText) != nil || nonEmpty(i.precedingText) != nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    // Breaks block-delimiter tags inside untrusted text by inserting a zero-width space after `<`.
    // Targeted to our own tag names, so ordinary `<` / `>` / "a < b" / "<3" pass through unchanged.
    static func neutralize(_ s: String) -> String {
        let pattern = #"(?i)<(/?)\s*(content|context|instructions|selection|preceding_text|app|field)\b"#
        guard let re = RegexCache.regex(pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "<\u{200B}$1$2")
    }
}
