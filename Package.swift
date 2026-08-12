// swift-tools-version:6.0
import PackageDescription
import Foundation

// Only the public production release bundles Sparkle for in-app updates. Gating the dependency at the
// manifest keeps Sparkle out of every other build's graph entirely — nothing to resolve, link, or
// sign — so dev builds and any downstream white-label build that supplies its own update mechanism
// carry no Sparkle burden. release.sh sets KEYSCRIBE_SPARKLE=1; everything else is Sparkle-free by
// default. Paired with a `#if canImport(Sparkle)` source guard and the .production runtime gate — see
// agent_notes/distribution_plan/sparkle.md.
let sparkleEnabled = ProcessInfo.processInfo.environment["KEYSCRIBE_SPARKLE"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "a95ec26ee05f19b5f6e69c62e1d4fae420537730"),
    .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    .package(url: "https://github.com/rsperko/speech-swift.git", revision: "96273cd375783531129e5bb97a7ec25a7e717994"),
    .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", revision: "0fb16ccb64252b23b17f87c2a8a61228df9e7ebd"),
]

var keyScribeDependencies: [Target.Dependency] = [
    "KeyScribeKit",
    "ObjCSupport",
    .product(name: "FluidAudio", package: "FluidAudio"),
    .product(name: "WhisperKit", package: "argmax-oss-swift"),
    .product(name: "Qwen3ASR", package: "speech-swift"),
    .product(name: "MoonshineVoice", package: "moonshine-swift"),
]

if sparkleEnabled {
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))
    keyScribeDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "KeyScribe",
    platforms: [.macOS("15.0")],
    // The app's code is a library so a downstream host that builds through a standard Xcode project can
    // link one product and inherit every dependency — and its pins — transitively, instead of re-declaring
    // them in a second place that silently drifts. The executable is a thin entry point over it.
    products: [
        .library(name: "KeyScribeKit", targets: ["KeyScribeKit"]),
        .library(name: "KeyScribeApp", targets: ["KeyScribeApp"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "KeyScribeKit",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .target(name: "ObjCSupport"),
        .target(
            name: "KeyScribeApp",
            dependencies: keyScribeDependencies,
            path: "Sources/KeyScribe"
        ),
        .executableTarget(
            name: "KeyScribe",
            dependencies: ["KeyScribeApp"],
            path: "Sources/KeyScribeMain"
        ),
        .testTarget(
            name: "KeyScribeKitTests",
            dependencies: ["KeyScribeKit"]
        ),
        .testTarget(
            name: "KeyScribeTests",
            dependencies: ["KeyScribeApp", "KeyScribeKit"]
        ),
    ]
)
