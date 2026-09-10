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

// Separate from `Modifier` because Fn belongs to a trigger and never to a Carbon chord.
public enum ModifierKey: String, Sendable, Hashable, CaseIterable {
    case control, option, shift, command, fn
}

public struct SidedModifier: Sendable, Hashable {
    public enum Side: String, Sendable, Hashable { case left, right }

    public let modifier: ModifierKey
    public let side: Side?

    public init(_ modifier: ModifierKey, _ side: Side? = nil) {
        self.modifier = modifier
        self.side = side
    }
}

public struct ModifierKeySet: Sendable, Hashable {
    // Hyper (⌃⌥⇧⌘) is the largest set anyone binds; a fifth member is a chord prefix, not a trigger.
    public static let maxMembers = 4

    public let members: Set<SidedModifier>

    public init(_ members: Set<SidedModifier>) throws {
        guard !members.isEmpty else { throw TriggerKeyError.empty }
        // Over `members`, not `ordered` — ordering keeps one entry per modifier, which would hide exactly
        // the case this rejects: left and right of the same key. Ahead of the count check, so a set that is
        // both oversized and clashing names the clash, which is the actionable half.
        var seen: Set<ModifierKey> = []
        for member in members.sorted(by: { $0.canonicalToken < $1.canonicalToken }) {
            guard seen.insert(member.modifier).inserted else {
                throw TriggerKeyError.duplicateModifier(member.modifier.rawValue)
            }
        }
        guard members.count <= ModifierKeySet.maxMembers else { throw TriggerKeyError.tooManyModifiers }
        self.members = members
    }


    public var ordered: [SidedModifier] { ModifierKeySet.order(members) }

    public func contains(_ modifier: ModifierKey) -> Bool { member(for: modifier) != nil }

    public func member(for modifier: ModifierKey) -> SidedModifier? {
        members.first { $0.modifier == modifier }
    }

    public var modifiers: Set<ModifierKey> { Set(members.map(\.modifier)) }

    // The compatibility relation. `collides`, the masking warning and `ModifierMatcher.engaged` must all
    // agree on it: `shadowedHotkeyIds` suppresses a colliding binding, so a pair called distinct here while
    // the matcher engages both is a live double-fire.
    public func canEngageTogether(with other: ModifierKeySet) -> Bool {
        modifiers == other.modifiers && sidesAgree(with: other)
    }

    // `left_command` is never held on the way into `right_command+control`, so sides gate this too.
    public func isMasked(by other: ModifierKeySet) -> Bool {
        modifiers.isStrictSubset(of: other.modifiers) && sidesAgree(with: other)
    }

    // A sideless member accepts either key; two sided members agree only on the same key.
    private func sidesAgree(with other: ModifierKeySet) -> Bool {
        members.allSatisfy { member in
            guard let counterpart = other.member(for: member.modifier) else { return true }
            return member.side == nil || counterpart.side == nil || member.side == counterpart.side
        }
    }

    private static func order(_ members: Set<SidedModifier>) -> [SidedModifier] {
        ModifierKey.allCases.compactMap { key in members.first { $0.modifier == key } }
    }
}

// A flagsChanged event's keyCode is the only place a modifier's side is observable.
public enum ModifierKeyCodes {
    public static func sidedModifier(forKeyCode keyCode: Int) -> SidedModifier? { byKeyCode[keyCode] }

    private static let byKeyCode: [Int: SidedModifier] = [
        55: SidedModifier(.command, .left), 54: SidedModifier(.command, .right),
        58: SidedModifier(.option, .left), 61: SidedModifier(.option, .right),
        59: SidedModifier(.control, .left), 62: SidedModifier(.control, .right),
        56: SidedModifier(.shift, .left), 60: SidedModifier(.shift, .right),
        63: SidedModifier(.fn),
    ]
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
    case modifiers(ModifierKeySet)
    case chord(modifiers: Set<Modifier>, key: BaseKey)
    case mouseButton(Int)
}

public enum TriggerKeyError: Error, Equatable {
    case empty
    case unknownToken(String)
    case bareNonFunctionKey
    case tooManyModifiers
    case duplicateModifier(String)
    case modifierNotAllowedInChord(String)
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

        if tokens.count == 1, let button = KeyDescriptor.mouseButtonNumber(token: first) {
            self = .mouseButton(button)
            return
        }

        // Every token a modifier and no base key → a modifier-only set; a base key present → a chord. A
        // chord's modifiers are the four Carbon ones, sideless: `RegisterEventHotKey` cannot distinguish
        // left from right and carries no Fn, so a sided or Fn token beside a base key is an error rather
        // than a silently-widened binding.
        var members: Set<SidedModifier> = []
        var seenModifiers: Set<ModifierKey> = []
        var chordIllegalTokens: [String] = []
        var base: BaseKey?
        for token in tokens {
            if let parsed = SidedModifier.parse(token: token) {
                // Per token, not per member: a set dedupes `command+command` and `hyper+control` into
                // something valid-looking, hiding a spelling the writer clearly did not mean.
                for member in parsed where !seenModifiers.insert(member.modifier).inserted {
                    throw TriggerKeyError.duplicateModifier(member.modifier.rawValue)
                }
                members.formUnion(parsed)
                if parsed.count > 1 || parsed.first?.side != nil || parsed.first?.modifier == .fn {
                    chordIllegalTokens.append(token)
                }
            } else if let k = BaseKey(token: token) {
                guard base == nil else { throw TriggerKeyError.unknownToken(token) }
                base = k
            } else {
                throw TriggerKeyError.unknownToken(token)
            }
        }

        guard let base else {
            self = .modifiers(try ModifierKeySet(members))
            return
        }
        if let rejected = chordIllegalTokens.first {
            throw TriggerKeyError.modifierNotAllowedInChord(rejected)
        }
        let modifiers = Set(members.compactMap(\.chordModifier))
        if modifiers.isEmpty, !base.isBareable { throw TriggerKeyError.bareNonFunctionKey }
        self = .chord(modifiers: modifiers, key: base)
    }

    public var canonical: String {
        switch self {
        case .modifiers(let set): return set.ordered.map(\.canonicalToken).joined(separator: "+")
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
        case .modifiers(let set): return Set(set.members.compactMap(\.chordModifier))
        case .chord(let mods, _): return mods
        case .mouseButton: return []
        }
    }

    public var requiredModifierMask: ModifierSet {
        ModifierSet(requiredModifiers)
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
        case let (.modifiers(a), .modifiers(b)): return a.canEngageTogether(with: b)
        case let (.chord(m1, k1), .chord(m2, k2)): return m1 == m2 && k1 == k2
        default: return false
        }
    }

    /// Carries at least one of ⌃⌥⇧⌘ — the modifiers a chord or a click can also carry, and therefore the
    /// sets those gestures can be confused with. An `fn`-only trigger is still modifier-only, but no chord
    /// or click ever sets the Fn flag, so nothing can shadow it.
    public var carriesChordModifier: Bool {
        guard case .modifiers(let set) = self else { return false }
        return set.members.contains { $0.modifier != .fn }
    }

    // Per-cap tokens for the wizard's keycap glyphs. The view renders one rounded cap per token;
    // an empty array means "no keycap" — the caller falls back to `displayString` plain text.
    public var keycapTokens: [String] {
        switch self {
        case .modifiers(let set): return set.ordered.map(\.keycapToken)
        case .chord(let mods, let key):
            return Modifier.allCases.filter { mods.contains($0) }.map(\.glyph) + [key.displayString]
        case .mouseButton: return []
        }
    }

    public var displayString: String {
        switch self {
        case .modifiers(let set): return set.displayString
        case .chord(let mods, let key):
            let glyphs = Modifier.allCases.filter { mods.contains($0) }.map(\.glyph).joined()
            return glyphs + key.displayString
        case .mouseButton(let n): return "Mouse Button \(n)"
        }
    }
}

extension SidedModifier {
    static func parse(token: String) -> Set<SidedModifier>? {
        if token == "hyper" {   // the one token that expands to several members
            return [.init(.control), .init(.option), .init(.shift), .init(.command)]
        }
        var side: Side?
        var name = token
        for prefix in ["left_", "right_"] where token.hasPrefix(prefix) {
            side = prefix == "left_" ? .left : .right
            name = String(token.dropFirst(prefix.count))
        }
        guard let modifier = ModifierKey(token: name) else { return nil }
        if modifier == .fn, side != nil { return nil }   // there is one Fn key, so `left_fn` names nothing
        return [SidedModifier(modifier, side)]
    }

    var canonicalToken: String {
        guard let side else { return modifier.rawValue }
        return "\(side.rawValue)_\(modifier.rawValue)"
    }

    var keycapToken: String {
        guard let side else { return modifier == .fn ? "fn" : modifier.glyph }
        return "\(side.rawValue) \(modifier.glyph)"
    }

    var displayToken: String {
        guard let side else { return modifier == .fn ? "Fn" : modifier.glyph }
        return "\(side.rawValue.capitalized)-\(modifier.glyph)"
    }

    var chordModifier: Modifier? { Modifier(rawValue: modifier.rawValue) }

    public var flipped: SidedModifier {
        guard let side else { return self }
        return SidedModifier(modifier, side == .left ? .right : .left)
    }
}

extension ModifierKeySet {
    // Byte-identical to the pre-set spellings for the five triggers that shipped before this grammar.
    var displayString: String {
        let ordered = self.ordered
        if ordered == [SidedModifier(.fn)] { return "Fn (Globe)" }
        if ordered.allSatisfy({ $0.side == nil && $0.modifier != .fn }) {
            return ordered.map(\.displayToken).joined()
        }
        return ordered.map(\.displayToken).joined(separator: " + ")
    }
}

extension ModifierKey {
    var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        case .fn: return "fn"
        }
    }

    init?(token: String) {
        switch token {
        case "control", "ctrl": self = .control
        case "option", "alt": self = .option
        case "shift": self = .shift
        case "command", "cmd": self = .command
        case "fn", "globe": self = .fn
        default: return nil
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
