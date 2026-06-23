import Foundation

enum KeyScribePaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyScribe", isDirectory: true)
    }

    static var modelsDir: URL {
        supportDir.appendingPathComponent("models", isDirectory: true)
    }

    static var modesDir: URL {
        supportDir.appendingPathComponent("modes", isDirectory: true)
    }
}
