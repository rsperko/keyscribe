public struct ShortcutProfile: Equatable, Sendable {
    public let allowsModifierOnly: Bool
    public let allowsMouseButtons: Bool

    public init(allowsModifierOnly: Bool, allowsMouseButtons: Bool) {
        self.allowsModifierOnly = allowsModifierOnly
        self.allowsMouseButtons = allowsMouseButtons
    }

    public static let modeTrigger = ShortcutProfile(allowsModifierOnly: true, allowsMouseButtons: true)
    public static let actionChord = ShortcutProfile(allowsModifierOnly: false, allowsMouseButtons: false)

    public var suggestedModifierTriggers: [KeyDescriptor] {
        allowsModifierOnly ? ShortcutProfile.modifierTriggerMenu : []
    }

    private static let modifierTriggerMenu: [KeyDescriptor] =
        ["fn", "right_option", "right_command", "right_control", "hyper"]
            .compactMap { try? KeyDescriptor(parsing: $0) }
}

public struct ShortcutCaptureModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, recording }

    public let profile: ShortcutProfile
    public private(set) var value: KeyDescriptor?
    public private(set) var rawFallback: String?
    public private(set) var phase: Phase = .idle
    public private(set) var hint: String?
    private var priorValue: KeyDescriptor?
    // The release of a multi-modifier press is staggered, so the set still held at the final release is a
    // subset of what the user meant. Recording the peak is what makes ⌃⌥⇧⌘ record as ⌃⌥⇧⌘, not as ⌘.
    private var peakModifiers: Set<SidedModifier> = []

    public init(profile: ShortcutProfile, stored: String) {
        self.profile = profile
        if stored.trimmingCharacters(in: .whitespaces).isEmpty {
            value = nil
        } else if let descriptor = try? KeyDescriptor(parsing: stored) {
            value = descriptor
        } else {
            rawFallback = stored
        }
    }

    public mutating func beginRecording() {
        priorValue = value
        clearModifiers()
        phase = .recording
        hint = nil
    }

    public mutating func keyEvent(
        keyCode: Int, shortcutCharacter: Character?, modifiers: Set<Modifier>
    ) -> KeyDescriptor? {
        guard phase == .recording else { return nil }
        clearModifiers()
        if let descriptor = KeyDescriptor(
            eventKeyCode: keyCode, shortcutCharacter: shortcutCharacter, modifiers: modifiers) {
            commit(descriptor)
            return descriptor
        }
        hint = modifiers.isEmpty ? "Hold a modifier (⌃⌥⇧⌘) with the key" : "That key can't be recorded"
        return nil
    }

    // Records nothing until every modifier is released with no key in between — that is what separates a
    // modifier-only trigger from a chord still being built.
    public mutating func modifierEvent(keyCode: Int, modifiers: Set<ModifierKey>) -> KeyDescriptor? {
        guard phase == .recording else { return nil }

        if let member = ModifierKeyCodes.sidedModifier(forKeyCode: keyCode),
           modifiers.contains(member.modifier) {
            peakModifiers.insert(member)
        }

        guard modifiers.isEmpty else { return nil }
        let captured = peakModifiers
        clearModifiers()
        guard !captured.isEmpty else { return nil }
        guard profile.allowsModifierOnly else {
            if captured.count >= 2 { noKeyOnModifierRelease() }
            return nil
        }
        do {
            // Every member keeps the physical key it was pressed on, however many there are — a recorded
            // trigger binds the keys the user actually used. The cost is accepted: an all-left ⌃⌥⇧⌘ stops
            // firing when they reach for the right ⇧, and reads as "Custom" rather than the menu's Hyper.
            let descriptor = KeyDescriptor.modifiers(try ModifierKeySet(captured))
            commit(descriptor)
            return descriptor
        } catch {
            hint = ShortcutCaptureModel.hint(for: error)
            return nil
        }
    }

    public mutating func mouseEvent(buttonNumber: Int) -> KeyDescriptor? {
        guard phase == .recording else { return nil }
        clearModifiers()
        guard profile.allowsMouseButtons else {
            hint = "Mouse buttons can't be used for this shortcut"
            return nil
        }
        guard let descriptor = KeyDescriptor(eventButtonNumber: buttonNumber) else { return nil }
        commit(descriptor)
        return descriptor
    }

    public mutating func cancel() {
        guard phase == .recording else { return }
        value = priorValue
        clearModifiers()
        phase = .idle
        hint = nil
    }

    public mutating func noKeyOnModifierRelease() {
        guard phase == .recording else { return }
        hint = "No key received — another app may already use this shortcut."
    }

    public mutating func select(_ newValue: KeyDescriptor?) {
        phase = .idle
        value = newValue
        rawFallback = nil
        hint = nil
    }

    private mutating func commit(_ descriptor: KeyDescriptor) {
        value = descriptor
        rawFallback = nil
        clearModifiers()
        phase = .idle
        hint = nil
    }

    private mutating func clearModifiers() {
        peakModifiers = []
    }

    private static func hint(for error: Error) -> String {
        switch error as? TriggerKeyError {
        case .duplicateModifier(let modifier):
            let glyph = ModifierKey(rawValue: modifier)?.glyph ?? modifier
            return "Left and right \(glyph) can't be combined"
        case .tooManyModifiers:
            return "Use at most four modifiers"
        default:
            return "That shortcut can't be recorded"
        }
    }
}
