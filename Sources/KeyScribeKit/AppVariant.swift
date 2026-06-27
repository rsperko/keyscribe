import Foundation

public enum AppVariant: Sendable, Equatable {
    case production
    case dev
    // A third, generic isolated variant: a build with its own config folder, keychain service, and
    // display name — derived from the running bundle, so no specific identity is baked into this repo.
    case custom(displayName: String, keychainService: String)

    private static let productionBundleID = "com.keyscribe.app"

    public init(bundleID: String?, bundleName: String? = nil) {
        guard let bundleID, bundleID != Self.productionBundleID else { self = .production; return }
        if bundleID.hasSuffix(".dev") {
            self = .dev
        } else {
            let name = bundleName.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
            self = .custom(displayName: name, keychainService: bundleID + ".llm")
        }
    }

    public var displayName: String {
        switch self {
        case .production: "KeyScribe"
        case .dev: "KeyScribeDev"
        case .custom(let displayName, _): displayName
        }
    }

    public var supportFolderName: String { displayName }

    public var keychainService: String {
        switch self {
        case .production: "com.keyscribe.llm"
        case .dev: "com.keyscribe.dev.llm"
        case .custom(_, let keychainService): keychainService
        }
    }

    public var isDev: Bool { self == .dev }

    // Downloaded weights are a large shared cache: every variant resolves models under the production
    // folder so a dev or custom build reuses the real models instead of re-downloading multiple gigabytes.
    public static let sharedModelsFolderName = AppVariant.production.supportFolderName
}
