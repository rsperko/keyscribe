import Foundation
import KeyScribeKit

// The user-facing product name, resolved once from the running bundle. Production builds resolve to
// "KeyScribe", the dev build to "KeyScribeDev", and a `custom` build (make-app.sh KEYSCRIBE_VARIANT=custom
// with KEYSCRIBE_BUNDLE_NAME) to whatever name that build ships under — so a downstream rebrand changes
// every user-facing string by setting its bundle name, with no source edits. Use this anywhere the app
// refers to itself in UI copy; never hardcode the literal name in a user-facing string.
enum Branding {
    static let appName: String = AppVariant(
        bundleID: Bundle.main.bundleIdentifier,
        bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    ).displayName
}
