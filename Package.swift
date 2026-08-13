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
    // Engine deps are pinned `exact:`/`revision:` for the same reason argmax-oss-swift is: they carry
    // recognition behavior, and a bump can change transcripts with no build error to warn you. Bumping
    // one is a deliberate act that must re-run the STT benchmark and the VAD gate (--vad-probe over
    // corpus/blips AND corpus/commands) — see AGENTS.md "Silence / no-speech behavior".
    // HELD at this revision: 0.15.5 FAILS the blips gate — see AGENTS.md "FluidAudio is held".
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "a95ec26ee05f19b5f6e69c62e1d4fae420537730"),
    .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    .package(url: "https://github.com/rsperko/speech-swift.git", revision: "96273cd375783531129e5bb97a7ec25a7e717994"),
    .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", exact: "0.1.2"),
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
    // `exact:` for the same reason argmax-oss-swift is pinned exactly, and one more: because Sparkle
    // is attached CONDITIONALLY, it never lands in Package.resolved (every non-release build resolves
    // without it), so a range here is a floating dependency that nothing records — the notarized
    // artifact could silently ship a different updater than the one that was smoke-tested. A version
    // range would be reproducible for any other dep; for this one only an exact pin is.
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"))
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
