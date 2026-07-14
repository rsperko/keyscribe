import AppKit
import KeyScribeKit

extension KeyDescriptor {
    // Display-only glyph: status-item menus sit outside `performKeyEquivalent:`'s main-menu walk, so
    // this never registers a competing hotkey or double-fires the event tap.
    var menuItemKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard case .chord(let modifiers, let base) = self else { return nil }
        let key: String
        switch base {
        case .letter(let c): key = String(c).lowercased()
        case .digit(let c): key = String(c)
        case .function(let n):
            guard let scalar = Unicode.Scalar(0xF704 + n - 1) else { return nil }
            key = String(Character(scalar))
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return (key, flags)
    }
}
