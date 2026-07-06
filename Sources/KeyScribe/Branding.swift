import Foundation
import KeyScribeKit

// The user-facing product name, resolved once from the running bundle ("KeyScribe" prod, "KeyScribeDev"
// dev, the bundle name for a `custom` rebrand) — so a downstream rebrand needs no source edits. Use
// anywhere the app refers to itself in UI copy; never hardcode the literal name.
enum Branding {
    static let appName: String = AppVariant(
        bundleID: Bundle.main.bundleIdentifier,
        bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    ).displayName
}
