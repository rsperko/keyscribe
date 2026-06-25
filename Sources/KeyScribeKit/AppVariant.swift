import Foundation

public enum AppVariant: Sendable, Equatable {
    case production
    case dev

    public init(bundleID: String?) {
        self = (bundleID?.hasSuffix(".dev") ?? false) ? .dev : .production
    }

    public var displayName: String {
        switch self {
        case .production: "KeyScribe"
        case .dev: "KeyScribeDev"
        }
    }

    public var supportFolderName: String { displayName }

    public var keychainService: String {
        switch self {
        case .production: "com.keyscribe.llm"
        case .dev: "com.keyscribe.dev.llm"
        }
    }

    public var isDev: Bool { self == .dev }

    // Downloaded weights are a large shared cache: every variant resolves models under the production
    // folder so a dev build reuses the real models instead of re-downloading multiple gigabytes.
    public static let sharedModelsFolderName = AppVariant.production.supportFolderName
}
