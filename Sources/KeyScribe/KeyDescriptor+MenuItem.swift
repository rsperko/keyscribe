import AppKit
import KeyScribeKit

extension KeyDescriptor {
    // Display-only glyph: status-item menus sit outside `performKeyEquivalent:`'s main-menu walk, so
    // this never registers a competing hotkey or double-fires the event tap.
    var menuItemKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard case .chord(let modifiers, let base) = self else { return nil }
        let key: String
        switch base {
        case .character(let c): key = String(c).lowercased()
        case .key(let special):
            guard let equivalent = special.menuKeyEquivalent else { return nil }
            key = equivalent
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if base.isKeypad { flags.insert(.numericPad) }
        return (key, flags)
    }
}

private extension BaseKey {
    var isKeypad: Bool {
        guard case .key(let special) = self else { return false }
        return special.rawValue.hasPrefix("keypad_")
    }
}

private extension SpecialKey {
    var menuKeyEquivalent: String? {
        switch self {
        case .space: return " "
        case .tab: return "\t"
        case .return, .keypadEnter: return "\r"
        case .delete: return "\u{8}"
        case .forwardDelete: return "\u{7f}"
        case .escape: return "\u{1b}"
        case .keypad0: return "0"
        case .keypad1: return "1"
        case .keypad2: return "2"
        case .keypad3: return "3"
        case .keypad4: return "4"
        case .keypad5: return "5"
        case .keypad6: return "6"
        case .keypad7: return "7"
        case .keypad8: return "8"
        case .keypad9: return "9"
        case .keypadDecimal: return "."
        case .keypadMultiply: return "*"
        case .keypadPlus: return "+"
        case .keypadMinus: return "-"
        case .keypadDivide: return "/"
        case .keypadEquals: return "="
        case .keypadClear: return nil
        default: return SpecialKey.functionKeyScalars[self].flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    static let functionKeyScalars: [SpecialKey: Int] = [
        .up: NSUpArrowFunctionKey, .down: NSDownArrowFunctionKey,
        .left: NSLeftArrowFunctionKey, .right: NSRightArrowFunctionKey,
        .home: NSHomeFunctionKey, .end: NSEndFunctionKey,
        .pageUp: NSPageUpFunctionKey, .pageDown: NSPageDownFunctionKey,
        .f1: NSF1FunctionKey, .f2: NSF2FunctionKey, .f3: NSF3FunctionKey, .f4: NSF4FunctionKey,
        .f5: NSF5FunctionKey, .f6: NSF6FunctionKey, .f7: NSF7FunctionKey, .f8: NSF8FunctionKey,
        .f9: NSF9FunctionKey, .f10: NSF10FunctionKey, .f11: NSF11FunctionKey, .f12: NSF12FunctionKey,
        .f13: NSF13FunctionKey, .f14: NSF14FunctionKey, .f15: NSF15FunctionKey, .f16: NSF16FunctionKey,
        .f17: NSF17FunctionKey, .f18: NSF18FunctionKey, .f19: NSF19FunctionKey, .f20: NSF20FunctionKey,
    ]
}
