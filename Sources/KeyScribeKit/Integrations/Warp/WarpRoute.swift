import Foundation

enum WarpRoute {
    static let focusKey = "WARP_FOCUS_URL"
    static let app = "dev.warp.Warp-Stable"
    static let route = KeyedSurfaceRoute(name: "Warp", apps: [app], key: focusKey, focus: .url(prefix: "warp://"))
}
