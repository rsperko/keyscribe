public enum Modifier: String, Sendable, CaseIterable {
    case control, option, shift, command
}

/// Allocation-free modifier set for the event-tap hot path: every keystroke compares the held
/// modifiers against a binding's required set, and a heap `Set<Modifier>` per event is wasteful.
public struct ModifierSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    public init(_ modifiers: Set<Modifier>) {
        var set: ModifierSet = []
        for m in modifiers { set.insert(m.mask) }
        self = set
    }
}

extension Modifier {
    var mask: ModifierSet {
        switch self {
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        case .command: return .command
        }
    }
}

public enum NamedKey: String, Sendable {
    case fn, hyper, rightOption, rightCommand, rightControl
}

public enum BaseKey: Equatable, Sendable {
    case letter(Character)
    case digit(Character)
    case function(Int)
}

public enum KeyDescriptor: Equatable, Sendable {
    case named(NamedKey)
    case chord(modifiers: Set<Modifier>, key: BaseKey)
    case mouseButton(Int)
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

        if tokens.count == 1, let button = KeyDescriptor.mouseButtonNumber(token: first) {
            self = .mouseButton(button)
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
        case .mouseButton(let n): return "mouse\(n)"
        }
    }

    static func mouseButtonNumber(token: String) -> Int? {
        guard token.hasPrefix("mouse"), let n = Int(token.dropFirst(5)), n >= 2 else { return nil }
        return n
    }

    public var requiredModifiers: Set<Modifier> {
        switch self {
        case .named(.hyper): return [.control, .option, .shift, .command]
        case .named(.rightOption): return [.option]
        case .named(.rightCommand): return [.command]
        case .named(.rightControl): return [.control]
        case .named(.fn): return []
        case .chord(let mods, _): return mods
        case .mouseButton: return []
        }
    }

    public var requiredModifierMask: ModifierSet {
        switch self {
        case .named(.hyper): return [.control, .option, .shift, .command]
        case .named(.rightOption): return [.option]
        case .named(.rightCommand): return [.command]
        case .named(.rightControl): return [.control]
        case .named(.fn): return []
        case .chord(let mods, _): return ModifierSet(mods)
        case .mouseButton: return []
        }
    }

    public var triggerKeyCode: Int {
        switch self {
        case .named(.fn): return 63
        case .named(.rightOption): return 61
        case .named(.rightCommand): return 54
        case .named(.rightControl): return 62
        case .named(.hyper): return 55
        case .chord(_, let key): return key.keyCode
        case .mouseButton(let n): return n
        }
    }

    /// Build a chord from a live-captured key event. Returns nil for an unrecognized key code
    /// or a bare non-function key (no modifier) — the cases a recorder must reject.
    public init?(eventKeyCode: Int, modifiers: Set<Modifier>) {
        guard let base = BaseKey(keyCode: eventKeyCode) else { return nil }
        if modifiers.isEmpty, case .function = base {} else if modifiers.isEmpty { return nil }
        self = .chord(modifiers: modifiers, key: base)
    }

    /// Build a mouse trigger from a live-captured mouse event. Rejects the primary buttons
    /// (left = 0, right = 1) so a trigger can never hijack a normal click.
    public init?(eventButtonNumber: Int) {
        guard eventButtonNumber >= 2 else { return nil }
        self = .mouseButton(eventButtonNumber)
    }

    /// Two descriptors collide when they would fire on the same physical event. Mouse buttons live in
    /// a separate input space from keys, so they only ever collide with the same mouse button.
    public func collides(with other: KeyDescriptor) -> Bool {
        switch (self, other) {
        case let (.mouseButton(a), .mouseButton(b)): return a == b
        case (.mouseButton, _), (_, .mouseButton): return false
        default: return triggerKeyCode == other.triggerKeyCode && requiredModifiers == other.requiredModifiers
        }
    }

    /// A modifier-only trigger fires the instant its modifiers are held (no key), so any chord or
    /// shortcut whose modifier set is a superset ALSO fires it. `fn` is excluded — it keys off the Fn
    /// flag, which no chord carries — as are chords and mouse buttons.
    public var isModifierOnly: Bool {
        switch self {
        case .named(.hyper), .named(.rightOption), .named(.rightCommand), .named(.rightControl): return true
        case .named(.fn), .chord, .mouseButton: return false
        }
    }

    // Per-cap tokens for the wizard's keycap glyphs. The view renders one rounded cap per token;
    // an empty array means "no keycap" — the caller falls back to `displayString` plain text.
    public var keycapTokens: [String] {
        switch self {
        case .named(.fn): return ["fn"]
        case .named(.hyper): return Modifier.allCases.map(\.glyph)
        case .named(.rightOption): return ["right ⌥"]
        case .named(.rightCommand): return ["right ⌘"]
        case .named(.rightControl): return ["right ⌃"]
        case .chord(let mods, let key):
            return Modifier.allCases.filter { mods.contains($0) }.map(\.glyph) + [key.displayString]
        case .mouseButton: return []
        }
    }

    public var displayString: String {
        switch self {
        case .named(.fn): return "Fn (Globe)"
        case .named(.hyper): return "⌃⌥⇧⌘"
        case .named(.rightOption): return "Right-⌥"
        case .named(.rightCommand): return "Right-⌘"
        case .named(.rightControl): return "Right-⌃"
        case .chord(let mods, let key):
            let glyphs = Modifier.allCases.filter { mods.contains($0) }.map(\.glyph).joined()
            return glyphs + key.displayString
        case .mouseButton(let n): return "Mouse Button \(n)"
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
        case "right_control": self = .rightControl
        default: return nil
        }
    }

    var canonicalToken: String {
        switch self {
        case .fn: return "fn"
        case .hyper: return "hyper"
        case .rightOption: return "right_option"
        case .rightCommand: return "right_command"
        case .rightControl: return "right_control"
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
            if BaseKey.letterKeyCodes[c] != nil { self = .letter(c); return }
            if BaseKey.digitKeyCodes[c] != nil { self = .digit(c); return }
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
