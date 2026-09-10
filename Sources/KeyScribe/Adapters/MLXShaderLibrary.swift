import Foundation
import Metal

// Mirrors MLX's load_default_library order (mlx/backend/metal/device.cpp), accepting only a library Metal
// opens. Assumes Cmlx is linked statically; MLX's framework and working-directory fallbacks are not modeled.
enum MLXShaderLibrary {
    static let swiftPMBundleName = "mlx-swift_Cmlx.bundle"

    static func candidates(executableDir: URL, bundleURL: URL, resourceURL: URL?) -> [URL] {
        var urls = [
            executableDir.appendingPathComponent("mlx.metallib"),
            executableDir.appendingPathComponent("Resources/mlx.metallib"),
            swiftPMLibrary(in: bundleURL),
        ]
        if let resourceURL { urls.append(swiftPMLibrary(in: resourceURL)) }
        urls.append(executableDir.appendingPathComponent("Resources/default.metallib"))
        return urls
    }

    static func selectedLibrary(
        executableDir: URL, bundleURL: URL, resourceURL: URL?, device: any MTLDevice
    ) -> URL? {
        candidates(executableDir: executableDir, bundleURL: bundleURL, resourceURL: resourceURL)
            .first { (try? device.makeLibrary(URL: $0)) != nil }
    }

    private static func swiftPMLibrary(in parent: URL) -> URL {
        let bundle = parent.appendingPathComponent(swiftPMBundleName, isDirectory: true)
        return (Bundle(url: bundle)?.resourceURL ?? bundle).appendingPathComponent("default.metallib")
    }

    static var liveCandidates: [URL] {
        candidates(
            executableDir: liveExecutableDir, bundleURL: Bundle.main.bundleURL, resourceURL: Bundle.main.resourceURL)
    }

    static func liveSelection() -> URL? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return selectedLibrary(
            executableDir: liveExecutableDir, bundleURL: Bundle.main.bundleURL,
            resourceURL: Bundle.main.resourceURL, device: device)
    }

    private static var liveExecutableDir: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
    }

    static let loadable: Bool = {
        if let url = liveSelection() {
            Log.models.notice("mlx shader library: \(url.path, privacy: .public)")
            return true
        }
        let searched = liveCandidates.map(\.path).joined(separator: ", ")
        Log.models.error("mlx shader library: none loadable; searched \(searched, privacy: .public)")
        return false
    }()
}
