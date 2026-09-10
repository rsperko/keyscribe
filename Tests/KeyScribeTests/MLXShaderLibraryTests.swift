import Foundation
import Metal
import Testing
@testable import KeyScribeApp

struct MLXShaderLibraryTests {
    private struct Layout {
        let root: URL
        let executableDir: URL
        let bundleURL: URL
        let resourceURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("keyscribe-mlx-probe-\(UUID().uuidString)", isDirectory: true)
            bundleURL = root.appendingPathComponent("Probe.app", isDirectory: true)
            executableDir = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            resourceURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        }

        func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        var colocated: URL { executableDir.appendingPathComponent("mlx.metallib") }
        var resourcesMLX: URL { executableDir.appendingPathComponent("Resources/mlx.metallib") }
        var resourcesDefault: URL { executableDir.appendingPathComponent("Resources/default.metallib") }

        func deepBundleLibrary() throws -> URL {
            let bundle = bundleURL.appendingPathComponent("mlx-swift_Cmlx.bundle", isDirectory: true)
            try write(Data(Self.infoPlist.utf8), to: bundle.appendingPathComponent("Contents/Info.plist"))
            return bundle.appendingPathComponent("Contents/Resources/default.metallib")
        }

        var flatBundleLibrary: URL {
            resourceURL.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib")
        }

        func select(_ device: MTLDevice) -> URL? {
            MLXShaderLibrary.selectedLibrary(
                executableDir: executableDir, bundleURL: bundleURL, resourceURL: resourceURL, device: device)
        }

        private static let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>mlx-swift.Cmlx.resources</string></dict></plist>
            """
    }

    private static let goodLibrary: Result<Data, Error> = Result {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-mlx-kernel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("probe.metal")
        try "kernel void keyscribe_probe(uint i [[thread_position_in_grid]]) {}".write(
            to: source, atomically: true, encoding: .utf8)
        let air = dir.appendingPathComponent("probe.air")
        let library = dir.appendingPathComponent("probe.metallib")
        try xcrun(["-sdk", "macosx", "metal", "-c", source.path, "-o", air.path])
        try xcrun(["-sdk", "macosx", "metallib", air.path, "-o", library.path])
        return try Data(contentsOf: library)
    }

    private struct ToolFailed: Error { let arguments: [String]; let status: Int32 }

    private static func xcrun(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolFailed(arguments: arguments, status: process.terminationStatus)
        }
    }

    private let corrupt = Data(repeating: 0x41, count: 4096)

    private func fixture() throws -> (Layout, Data, MTLDevice) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return (try Layout(), try Self.goodLibrary.get(), device)
    }

    private func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    @Test func nothingPresentSelectsNothing() throws {
        let (layout, _, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        #expect(layout.select(device) == nil)
    }

    @Test func aGoodColocatedLibraryIsSelected() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(good, to: layout.colocated)
        #expect(samePath(layout.select(device), layout.colocated))
    }

    @Test func aGoodDeepSwiftPMBundleIsSelected() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let library = try layout.deepBundleLibrary()
        try layout.write(good, to: library)
        #expect(samePath(layout.select(device), library))
    }

    @Test func aGoodFlatSwiftPMBundleIsSelected() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(good, to: layout.flatBundleLibrary)
        #expect(samePath(layout.select(device), layout.flatBundleLibrary))
    }

    @Test func aCorruptColocatedLibraryAloneSelectsNothing() throws {
        let (layout, _, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(corrupt, to: layout.colocated)
        #expect(layout.select(device) == nil)
    }

    @Test func aCorruptBundleLibraryAloneSelectsNothing() throws {
        let (layout, _, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(corrupt, to: layout.flatBundleLibrary)
        #expect(layout.select(device) == nil)
    }

    @Test func aCorruptColocatedLibraryFallsThroughToAGoodBundle() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(corrupt, to: layout.colocated)
        try layout.write(good, to: layout.flatBundleLibrary)
        #expect(samePath(layout.select(device), layout.flatBundleLibrary))
    }

    @Test func aGoodColocatedLibraryWinsOverAGoodBundle() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(good, to: layout.colocated)
        try layout.write(good, to: layout.flatBundleLibrary)
        #expect(samePath(layout.select(device), layout.colocated))
    }

    @Test func aGoodResourcesMLXLibraryWinsOverAGoodBundle() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(good, to: layout.resourcesMLX)
        try layout.write(good, to: try layout.deepBundleLibrary())
        #expect(samePath(layout.select(device), layout.resourcesMLX))
    }

    @Test func aGoodBundleWinsOverAGoodResourcesDefaultLibrary() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let library = try layout.deepBundleLibrary()
        try layout.write(good, to: library)
        try layout.write(good, to: layout.resourcesDefault)
        #expect(samePath(layout.select(device), library))
    }

    @Test func aGoodResourcesDefaultLibraryIsTheLastModeledCandidate() throws {
        let (layout, good, device) = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.write(corrupt, to: layout.colocated)
        try layout.write(good, to: layout.resourcesDefault)
        #expect(samePath(layout.select(device), layout.resourcesDefault))
    }
}
