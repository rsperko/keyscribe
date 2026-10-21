import AppKit
import KeyScribeKit
import SwiftUI

extension HUDAppearance {
    @MainActor static var systemIsDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @MainActor func nsAppearance(
        systemIsDark: Bool = HUDAppearance.systemIsDark,
        increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    ) -> NSAppearance? {
        Self.appearanceName(resolved(systemIsDark: systemIsDark), increaseContrast: increaseContrast)
            .flatMap(NSAppearance.init(named:))
    }

    // A named appearance replaces the inherited one wholesale, so it must carry the high-contrast variant
    // itself or pinning Light/Dark would silently drop Increase Contrast.
    static func appearanceName(_ scheme: Scheme?, increaseContrast: Bool) -> NSAppearance.Name? {
        switch (scheme, increaseContrast) {
        case (nil, _): nil
        case (.light, false): .aqua
        case (.light, true): .accessibilityHighContrastAqua
        case (.dark, false): .darkAqua
        case (.dark, true): .accessibilityHighContrastDarkAqua
        }
    }
}

extension Color {
    static func recording(in scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.56, green: 0.11, blue: 0.18) : .red
    }
}
