import CryptoKit
import Foundation

enum ConnectorResources {
    private final class BundleMarker {}

    static let bundleName = "KeyScribe_KeyScribeApp.bundle"

    static func bundleLocations() -> [URL] {
        let code = Bundle(for: BundleMarker.self)
        let places: [URL?] = [
            Bundle.main.resourceURL, Bundle.main.bundleURL, code.resourceURL, code.bundleURL, code.bundleURL.deletingLastPathComponent(),
        ]
        return places.compactMap { $0?.appendingPathComponent(bundleName, isDirectory: true) }
    }

    static func text(named name: String, extension ext: String, searching bundles: [URL] = bundleLocations()) -> String? {
        for url in bundles {
            guard let bundle = Bundle(url: url), let file = bundle.url(forResource: name, withExtension: ext),
                  let text = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            return text
        }
        return nil
    }

    static func version(for text: String) -> String {
        "0.1.0-" + SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
