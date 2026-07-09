import Foundation
import KeyScribeKit

actor RequestAdaptationCache {
    static let shared = RequestAdaptationCache()

    private var entries: [String: RequestAdaptations] = [:]

    func lookup(_ key: String) -> RequestAdaptations? { entries[key] }

    func remember(_ adaptations: RequestAdaptations, for key: String) { entries[key] = adaptations }

    func reset() { entries.removeAll() }
}
