public enum Modifier: String, Sendable, CaseIterable {
    case control, option, shift, command
}

public enum NamedKey: String, Sendable {
    case fn, hyper, rightOption, rightCommand
}

public enum BaseKey: Equatable, Sendable {
    case letter(Character)
    case digit(Character)
    case function(Int)
}

public enum KeyDescriptor: Equatable, Sendable {
    case named(NamedKey)
    case chord(modifiers: Set<Modifier>, key: BaseKey)
}

public enum TriggerKeyError: Error, Equatable {
    case empty
    case unknownToken(String)
    case noBaseKey
    case bareNonFunctionKey
}

extension KeyDescriptor {
    public init(parsing string: String) throws {
        let tokens = string
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { token -> String in
                String(token.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
                    .lowercased()
            }
        guard !tokens.contains(where: \.isEmpty), let first = tokens.first, !first.isEmpty else {
            throw TriggerKeyError.empty
        }

        if tokens.count == 1, let named = NamedKey(token: first) {
            self = .named(named)
            return
        }

        var modifiers: Set<Modifier> = []
        var base: BaseKey?
        for token in tokens {
            if let m = Modifier(token: token) {
                modifiers.insert(m)
            } else if let k = BaseKey(token: token) {
                guard base == nil else { throw TriggerKeyError.unknownToken(token) }
                base = k
            } else {
                throw TriggerKeyError.unknownToken(token)
            }
        }

        guard let base else { throw TriggerKeyError.noBaseKey }
        if modifiers.isEmpty, case .function = base {} else if modifiers.isEmpty {
            throw TriggerKeyError.bareNonFunctionKey
        }
        self = .chord(modifiers: modifiers, key: base)
    }

    public var canonical: String {
        switch self {
        case .named(let n): return n.canonicalToken
        case .chord(let mods, let key):
            let ordered = Modifier.allCases.filter { mods.contains($0) }.map(\.rawValue)
            return (ordered + [key.canonicalToken]).joined(separator: "+")
        }
    }

    public var requiredModifiers: Set<Modifier> {
        switch self {
        case .named(.hyper): return [.control, .option, .shift, .command]
        case .named(.rightOption): return [.option]
        case .named(.rightCommand): return [.command]
        case .named(.fn): return []
        case .chord(let mods, _): return mods
        }
    }

    public var triggerKeyCode: Int {
        switch self {
        case .named(.fn): return 63
        case .named(.rightOption): return 61
        case .named(.rightCommand): return 54
        case .named(.hyper): return 55
        case .chord(_, let key): return key.keyCode
        }
    }

    /// Exact chord match: the base key matches AND the active modifiers equal the required set
    /// exactly — no extras. This is what stops `option+l` from firing under `hyper+l`
    /// (ctrl+option+shift+command+l), where Option is merely a subset of what's held.
    public func matchesChord(keyCode: Int, activeModifiers: Set<Modifier>) -> Bool {
        guard case .chord = self else { return false }
        return keyCode == triggerKeyCode && activeModifiers == requiredModifiers
    }

    /// Build a chord from a live-captured key event. Returns nil for an unrecognized key code
    /// or a bare non-function key (no modifier) — the cases a recorder must reject.
    public init?(eventKeyCode: Int, modifiers: Set<Modifier>) {
        guard let base = BaseKey(keyCode: eventKeyCode) else { return nil }
        if modifiers.isEmpty, case .function = base {} else if modifiers.isEmpty { return nil }
        self = .chord(modifiers: modifiers, key: base)
    }

    /// Two descriptors collide when they would fire on the same physical event.
    public func collides(with other: KeyDescriptor) -> Bool {
        triggerKeyCode == other.triggerKeyCode && requiredModifiers == other.requiredModifiers
    }

    public var displayString: String {
        switch self {
        case .named(.fn): return "Fn (Globe)"
        case .named(.hyper): return "Hyper (⌃⌥⇧⌘)"
        case .named(.rightOption): return "Right ⌥"
        case .named(.rightCommand): return "Right ⌘"
        case .chord(let mods, let key):
            let glyphs = Modifier.allCases.filter { mods.contains($0) }.map(\.glyph).joined()
            return glyphs + key.displayString
        }
    }
}

extension NamedKey {
    init?(token: String) {
        switch token {
        case "fn", "globe": self = .fn
        case "hyper": self = .hyper
        case "right_option": self = .rightOption
        case "right_command": self = .rightCommand
        default: return nil
        }
    }

    var canonicalToken: String {
        switch self {
        case .fn: return "fn"
        case .hyper: return "hyper"
        case .rightOption: return "right_option"
        case .rightCommand: return "right_command"
        }
    }
}

extension Modifier {
    var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    init?(token: String) {
        switch token {
        case "control", "ctrl": self = .control
        case "option", "alt": self = .option
        case "shift": self = .shift
        case "command", "cmd": self = .command
        default: return nil
        }
    }
}

extension BaseKey {
    init?(token: String) {
        if token.count == 1, let c = token.first {
            if c.isLetter { self = .letter(c); return }
            if c.isNumber { self = .digit(c); return }
        }
        if token.first == "f", let n = Int(token.dropFirst()), (1...20).contains(n) {
            self = .function(n)
            return
        }
        return nil
    }

    init?(keyCode: Int) {
        if let c = BaseKey.letterKeyCodes.first(where: { $0.value == keyCode })?.key { self = .letter(c); return }
        if let c = BaseKey.digitKeyCodes.first(where: { $0.value == keyCode })?.key { self = .digit(c); return }
        if let n = BaseKey.functionKeyCodes.first(where: { $0.value == keyCode })?.key { self = .function(n); return }
        return nil
    }

    var canonicalToken: String {
        switch self {
        case .letter(let c): return String(c)
        case .digit(let c): return String(c)
        case .function(let n): return "f\(n)"
        }
    }

    var displayString: String {
        switch self {
        case .letter(let c): return String(c).uppercased()
        case .digit(let c): return String(c)
        case .function(let n): return "F\(n)"
        }
    }

    var keyCode: Int {
        switch self {
        case .letter(let c): return BaseKey.letterKeyCodes[c] ?? -1
        case .digit(let c): return BaseKey.digitKeyCodes[c] ?? -1
        case .function(let n): return BaseKey.functionKeyCodes[n] ?? -1
        }
    }

    static let letterKeyCodes: [Character: Int] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
        "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    ]
    static let digitKeyCodes: [Character: Int] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
    static let functionKeyCodes: [Int: Int] = [
        1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109,
        11: 103, 12: 111, 13: 105, 14: 107, 15: 113, 16: 106, 17: 64, 18: 79, 19: 80, 20: 90,
    ]
}
