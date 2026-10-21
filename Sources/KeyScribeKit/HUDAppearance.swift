public enum HUDAppearance: String, Codable, Sendable, Equatable, CaseIterable {
    case system, light, dark, opposite

    public enum Scheme: Sendable, Equatable {
        case light, dark
    }

    public func resolved(systemIsDark: Bool) -> Scheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        case .opposite: systemIsDark ? .light : .dark
        }
    }
}
