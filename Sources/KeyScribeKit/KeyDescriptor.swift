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

public enum SpecialKey: String, Sendable, Hashable, CaseIterable {
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20
    case space, tab, `return`, delete, escape
    case forwardDelete = "forward_delete"
    case home, end
    case pageUp = "page_up"
    case pageDown = "page_down"
    case up, down, left, right
    case keypad0 = "keypad_0"
    case keypad1 = "keypad_1"
    case keypad2 = "keypad_2"
    case keypad3 = "keypad_3"
    case keypad4 = "keypad_4"
    case keypad5 = "keypad_5"
    case keypad6 = "keypad_6"
    case keypad7 = "keypad_7"
    case keypad8 = "keypad_8"
    case keypad9 = "keypad_9"
    case keypadDecimal = "keypad_decimal"
    case keypadMultiply = "keypad_multiply"
    case keypadPlus = "keypad_plus"
    case keypadMinus = "keypad_minus"
    case keypadDivide = "keypad_divide"
    case keypadEquals = "keypad_equals"
    case keypadEnter = "keypad_enter"
    case keypadClear = "keypad_clear"

    public var keyCode: Int {
        switch self {
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .f16: return 106
        case .f17: return 64
        case .f18: return 79
        case .f19: return 80
        case .f20: return 90
        case .space: return 49
        case .tab: return 48
        case .return: return 36
        case .delete: return 51
        case .escape: return 53
        case .forwardDelete: return 117
        case .home: return 115
        case .end: return 119
        case .pageUp: return 116
        case .pageDown: return 121
        case .up: return 126
        case .down: return 125
        case .left: return 123
        case .right: return 124
        case .keypad0: return 82
        case .keypad1: return 83
        case .keypad2: return 84
        case .keypad3: return 85
        case .keypad4: return 86
        case .keypad5: return 87
        case .keypad6: return 88
        case .keypad7: return 89
        case .keypad8: return 91
        case .keypad9: return 92
        case .keypadDecimal: return 65
        case .keypadMultiply: return 67
        case .keypadPlus: return 69
        case .keypadMinus: return 78
        case .keypadDivide: return 75
        case .keypadEquals: return 81
        case .keypadEnter: return 76
        case .keypadClear: return 71
        }
    }

    public init?(keyCode: Int) {
        guard let match = SpecialKey.byKeyCode[keyCode] else { return nil }
        self = match
    }

    public var isFunctionKey: Bool {
        SpecialKey.functionRow.contains(self)
    }

    public var displayString: String {
        switch self {
        case .space: return "␣"
        case .tab: return "⇥"
        case .return: return "↩"
        case .delete: return "⌫"
        case .forwardDelete: return "⌦"
        case .escape: return "⎋"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .keypadEnter: return "Keypad ⌤"
        case .keypadClear: return "Keypad Clear"
        case .keypadDecimal: return "Keypad ."
        case .keypadMultiply: return "Keypad *"
        case .keypadPlus: return "Keypad +"
        case .keypadMinus: return "Keypad -"
        case .keypadDivide: return "Keypad /"
        case .keypadEquals: return "Keypad ="
        case .keypad0: return "Keypad 0"
        case .keypad1: return "Keypad 1"
        case .keypad2: return "Keypad 2"
        case .keypad3: return "Keypad 3"
        case .keypad4: return "Keypad 4"
        case .keypad5: return "Keypad 5"
        case .keypad6: return "Keypad 6"
        case .keypad7: return "Keypad 7"
        case .keypad8: return "Keypad 8"
        case .keypad9: return "Keypad 9"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return rawValue.uppercased()
        }
    }

    private static let functionRow: Set<SpecialKey> = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]

    private static let byKeyCode: [Int: SpecialKey] =
        Dictionary(uniqueKeysWithValues: SpecialKey.allCases.map { ($0.keyCode, $0) })
}

public enum BaseKey: Equatable, Sendable, Hashable {
    case character(Character)
    case key(SpecialKey)
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
        if modifiers.isEmpty, !base.isBareable { throw TriggerKeyError.bareNonFunctionKey }
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

    public func chordKeyCode(in layout: KeyboardLayoutIndex) -> Int? {
        guard case .chord(_, let base) = self else { return nil }
        switch base {
        case .key(let special): return special.keyCode
        case .character(let c): return layout.shortcutKeyCode(for: c)
        }
    }

    public init?(eventKeyCode: Int, shortcutCharacter: Character?, modifiers: Set<Modifier>) {
        let base: BaseKey
        if let special = SpecialKey(keyCode: eventKeyCode) {
            base = .key(special)
        } else if let character = shortcutCharacter, let normalized = BaseKey.normalized(character) {
            base = .character(normalized)
        } else {
            return nil
        }
        if modifiers.isEmpty, !base.isBareable { return nil }
        self = .chord(modifiers: modifiers, key: base)
    }

    /// Build a mouse trigger from a live-captured mouse event. Rejects the primary buttons
    /// (left = 0, right = 1) so a trigger can never hijack a normal click.
    public init?(eventButtonNumber: Int) {
        guard eventButtonNumber >= 2 else { return nil }
        self = .mouseButton(eventButtonNumber)
    }

    public func collides(with other: KeyDescriptor) -> Bool {
        switch (self, other) {
        case let (.mouseButton(a), .mouseButton(b)): return a == b
        case let (.named(a), .named(b)): return a == b
        case let (.chord(m1, k1), .chord(m2, k2)): return m1 == m2 && k1 == k2
        default: return false
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

    public var keyCode: Int {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .hyper: return 55
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
        if let special = SpecialKey(rawValue: token) { self = .key(special); return }
        if let aliased = BaseKey.punctuationAliases[token] { self = .character(aliased); return }
        if token.count == 1, let c = token.first, let normalized = BaseKey.normalized(c) {
            self = .character(normalized)
            return
        }
        return nil
    }

    var canonicalToken: String {
        switch self {
        case .character(let c):
            return c == "+" ? "plus" : String(c)
        case .key(let special): return special.rawValue
        }
    }

    var displayString: String {
        switch self {
        case .character(let c): return String(c).uppercased()
        case .key(let special): return special.displayString
        }
    }

    var isBareable: Bool {
        guard case .key(let special) = self else { return false }
        return special.isFunctionKey
    }

    static func normalized(_ character: Character) -> Character? {
        guard !character.isWhitespace,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        let lowered = String(character).lowercased()
        guard lowered.count == 1, let first = lowered.first else { return character }
        return first
    }

    static let punctuationAliases: [String: Character] = ["plus": "+"]
}
