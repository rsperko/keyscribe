import Foundation
import KeyScribeKit

// The only place the literal app name should be hardcoded — the white-label seam for downstream
// rebrands. Interpolate `Branding.appName` everywhere else instead of hardcoding "KeyScribe".
enum Branding {
    static let appName: String = AppVariant(
        bundleID: Bundle.main.bundleIdentifier,
        bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    ).displayName
}
