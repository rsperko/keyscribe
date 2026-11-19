import Foundation

struct CodexTOMLScan {
    struct Token {
        enum Kind { case newline, space, comment, string, open, close, openBrace, closeBrace, comma, equals, dot, bare }
        var kind: Kind
        var start: Int
        var end: Int
    }

    struct Header {
        var path: [String]
        var isArray: Bool
        var lineStart: Int
        var lineEnd: Int
    }

    struct Entry {
        var path: [String]
        var section: Int?
        var lineStart: Int
        var valueToken: Int
        var lineEnd: Int
    }

    struct ArrayLayout {
        struct Item {
            var range: Range<Int>
            var isElement: Bool
        }
        var open: Range<Int>
        var close: Range<Int>
        var items: [Item]
    }

    let bytes: [UInt8]
    let tokens: [Token]
    private(set) var headers: [Header] = []
    private(set) var entries: [Entry] = []

    init?(_ bytes: [UInt8]) {
        guard let tokens = Self.lex(bytes) else { return nil }
        self.bytes = bytes
        self.tokens = tokens
        guard parse() else { return nil }
    }

    var tuiSection: Int? {
        headers.firstIndex { !$0.isArray && $0.path == [CodexTitleItem.table] }
    }

    var header: Header? { tuiSection.map { headers[$0] } }

    func layout(of entry: Entry) -> ArrayLayout? {
        guard tokens[entry.valueToken].kind == .open else { return nil }
        let open = tokens[entry.valueToken]
        var items: [ArrayLayout.Item] = []
        var current: Range<Int>?
        func flush() {
            if let range = current { items.append(.init(range: range, isElement: true)) }
            current = nil
        }
        var index = entry.valueToken + 1
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .comma:
                flush()
                items.append(.init(range: token.start..<token.end, isElement: false))
            case .close:
                flush()
                return ArrayLayout(open: open.start..<open.end, close: token.start..<token.end, items: items)
            case .newline, .comment:
                flush()
            case .space:
                break
            case .open, .openBrace:
                guard let match = matching(index) else { return nil }
                current = (current?.lowerBound ?? token.start)..<tokens[match].end
                index = match
            default:
                current = (current?.lowerBound ?? token.start)..<token.end
            }
            index += 1
        }
        return nil
    }

    private func matching(_ start: Int) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            switch tokens[index].kind {
            case .open, .openBrace: depth += 1
            case .close, .closeBrace:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    private mutating func parse() -> Bool {
        var index = 0
        var lineStart = 0
        var section: Int?
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .newline:
                lineStart = token.end
                index += 1
            case .space, .comment:
                index += 1
            case .open:
                var next = index + 1
                let isArray = next < tokens.count && tokens[next].kind == .open && tokens[next].start == token.end
                if isArray { next += 1 }
                guard let (path, close) = keyPath(from: next, until: .close) else { return false }
                var after = close + 1
                if isArray {
                    guard after < tokens.count, tokens[after].kind == .close, tokens[after].start == tokens[close].end else { return false }
                    after += 1
                }
                guard let (resume, lineEnd) = restOfLine(from: after) else { return false }
                headers.append(Header(path: path, isArray: isArray, lineStart: lineStart, lineEnd: lineEnd))
                section = headers.count - 1
                lineStart = lineEnd
                index = resume
            case .bare, .string:
                guard let (path, equals) = keyPath(from: index, until: .equals) else { return false }
                var cursor = equals + 1
                var depth = 0
                var first: Int?
                while cursor < tokens.count, depth > 0 || tokens[cursor].kind != .newline {
                    switch tokens[cursor].kind {
                    case .open, .openBrace: depth += 1
                    case .close, .closeBrace: depth -= 1
                    default: break
                    }
                    guard depth >= 0 else { return false }
                    if first == nil, ![.space, .comment, .newline].contains(tokens[cursor].kind) { first = cursor }
                    cursor += 1
                }
                guard depth == 0, let first else { return false }
                let lineEnd = cursor < tokens.count ? tokens[cursor].end : bytes.count
                entries.append(Entry(path: path, section: section, lineStart: lineStart, valueToken: first, lineEnd: lineEnd))
                lineStart = lineEnd
                index = cursor + 1
            default:
                return false
            }
        }
        return true
    }

    private func restOfLine(from start: Int) -> (resume: Int, lineEnd: Int)? {
        var index = start
        while index < tokens.count {
            switch tokens[index].kind {
            case .space, .comment: index += 1
            case .newline: return (index + 1, tokens[index].end)
            default: return nil
            }
        }
        return (index, bytes.count)
    }

    private func keyPath(from start: Int, until end: Token.Kind) -> (path: [String], end: Int)? {
        var path: [String] = []
        var index = start
        while true {
            while index < tokens.count, tokens[index].kind == .space { index += 1 }
            guard index < tokens.count, [.bare, .string].contains(tokens[index].kind) else { return nil }
            path.append(keyName(tokens[index]))
            index += 1
            while index < tokens.count, tokens[index].kind == .space { index += 1 }
            guard index < tokens.count else { return nil }
            if tokens[index].kind == end { return (path, index) }
            guard tokens[index].kind == .dot else { return nil }
            index += 1
        }
    }

    private func keyName(_ token: Token) -> String {
        let raw = String(decoding: bytes[token.start..<token.end], as: UTF8.self)
        guard token.kind == .string, raw.count >= 2 else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    private static func lex(_ bytes: [UInt8]) -> [Token]? {
        let newline = UInt8(ascii: "\n")
        let space = UInt8(ascii: " ")
        let tab = UInt8(ascii: "\t")
        let carriageReturn = UInt8(ascii: "\r")
        let doubleQuote = UInt8(ascii: "\"")
        let singleQuote = UInt8(ascii: "'")
        let backslash = UInt8(ascii: "\\")
        let punctuation: [UInt8: Token.Kind] = [
            UInt8(ascii: "["): .open, UInt8(ascii: "]"): .close, UInt8(ascii: "{"): .openBrace, UInt8(ascii: "}"): .closeBrace,
            UInt8(ascii: ","): .comma, UInt8(ascii: "="): .equals, UInt8(ascii: "."): .dot,
        ]
        let delimiters: Set<UInt8> = Set(punctuation.keys).union([newline, space, tab, carriageReturn, UInt8(ascii: "#"), doubleQuote, singleQuote])

        func tripled(_ quote: UInt8, at index: Int) -> Bool {
            index + 2 < bytes.count && bytes[index] == quote && bytes[index + 1] == quote && bytes[index + 2] == quote
        }

        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            let start = index
            let byte = bytes[index]
            let kind: Token.Kind
            if byte == newline {
                index += 1
                kind = .newline
            } else if byte == space || byte == tab || byte == carriageReturn {
                while index < bytes.count, [space, tab, carriageReturn].contains(bytes[index]) { index += 1 }
                kind = .space
            } else if byte == UInt8(ascii: "#") {
                while index < bytes.count, bytes[index] != newline { index += 1 }
                kind = .comment
            } else if byte == doubleQuote || byte == singleQuote {
                let escapes = byte == doubleQuote
                if tripled(byte, at: index) {
                    index += 3
                    while true {
                        guard index < bytes.count else { return nil }
                        if escapes, bytes[index] == backslash {
                            index += 2
                        } else if tripled(byte, at: index) {
                            index += 3
                            var extra = 0
                            while extra < 2, index < bytes.count, bytes[index] == byte {
                                index += 1
                                extra += 1
                            }
                            break
                        } else {
                            index += 1
                        }
                    }
                } else {
                    index += 1
                    while true {
                        guard index < bytes.count, bytes[index] != newline else { return nil }
                        if escapes, bytes[index] == backslash {
                            index += 2
                        } else if bytes[index] == byte {
                            index += 1
                            break
                        } else {
                            index += 1
                        }
                    }
                }
                kind = .string
            } else if let mark = punctuation[byte] {
                index += 1
                kind = mark
            } else {
                while index < bytes.count, !delimiters.contains(bytes[index]) { index += 1 }
                kind = .bare
            }
            tokens.append(Token(kind: kind, start: start, end: min(index, bytes.count)))
        }
        return tokens
    }
}
