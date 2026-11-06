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

struct HUDCardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            // A light card usually floats over dark content, which bleeds through the standard material as grey.
            .background(colorScheme == .light ? .thickMaterial : .regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                Color.primary.opacity(contrast == .increased ? 0.5 : 0.2),
                lineWidth: contrast == .increased ? 1.5 : 1))
    }
}
