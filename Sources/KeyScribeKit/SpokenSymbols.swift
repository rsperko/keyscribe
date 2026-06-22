import Foundation

// Spoken-symbol expansion for code/terminal dictation: "open paren" → "(", "backslash" → "\".
// Opt-in per mode (commands.symbols) because the same phrases ("dot", "comma", "colon") are ordinary
// words in prose; a mode enables it only when symbol-dense input is expected. This is mode *data*
// (a toggle the generic stage reads), never app identity. Multi-word phrases match longest-first so
// "open parenthesis" wins over a hypothetical "open". Word spacing is preserved as spoken; tightening
// "foo ( bar )" → "foo(bar)" is left to the LLM rewrite or the user.
public enum SpokenSymbols {
    public static let defaultMap: [String: String] = [
        "open paren": "(", "open parenthesis": "(", "close paren": ")", "close parenthesis": ")",
        "open bracket": "[", "close bracket": "]",
        "open brace": "{", "close brace": "}", "open curly": "{", "close curly": "}",
        "open angle bracket": "<", "close angle bracket": ">",
        "ampersand": "&", "at sign": "@", "hash sign": "#", "pound sign": "#", "hashtag": "#",
        "dollar sign": "$", "percent sign": "%", "caret": "^", "asterisk": "*",
        "backslash": "\\", "forward slash": "/", "pipe": "|", "vertical bar": "|",
        "tilde": "~", "backtick": "`", "underscore": "_",
        "plus sign": "+", "equals sign": "=", "minus sign": "-",
        "open quote": "\"", "close quote": "\"", "double quote": "\"", "single quote": "'",
        "semicolon": ";", "colon": ":",
    ]

    public static func apply(_ text: String, map: [String: String] = defaultMap) -> String {
        guard !map.isEmpty else { return text }
        let phrases = map.keys.map { $0.split(separator: " ").map(String.init) }
        let maxWords = phrases.map(\.count).max() ?? 1
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            for span in stride(from: min(maxWords, tokens.count - i), through: 1, by: -1) {
                let phrase = tokens[i..<i + span].map { $0.lowercased() }.joined(separator: " ")
                if let symbol = map[phrase] {
                    out.append(symbol)
                    i += span
                    matched = true
                    break
                }
            }
            if !matched { out.append(tokens[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }
}

public struct SymbolsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.spokenSymbols
    public let map: [String: String]
    public init(map: [String: String] = SpokenSymbols.defaultMap) { self.map = map }
    public func run(_ context: inout PipelineContext) {
        context.text = SpokenSymbols.apply(context.text, map: map)
    }
}
