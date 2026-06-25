import Foundation
import KeyScribeKit

enum HUDAnchorStore {
    static let defaultsKey = "hudAnchor"

    static func load(_ defaults: UserDefaults = .standard) -> HUDAnchor {
        guard let raw = defaults.string(forKey: defaultsKey),
              let anchor = HUDAnchor(rawValue: raw) else { return .default }
        return anchor
    }

    static func save(_ anchor: HUDAnchor, _ defaults: UserDefaults = .standard) {
        defaults.set(anchor.rawValue, forKey: defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
