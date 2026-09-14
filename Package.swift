// swift-tools-version:6.0
import PackageDescription

let packageDependencies: [Package.Dependency] = [
    // Engine deps are pinned `exact:`/`revision:` for the same reason argmax-oss-swift is: they carry
    // recognition behavior, and a bump can change transcripts with no build error to warn you. Bumping
    // one is a deliberate act that must re-run the STT benchmark and the VAD gate (--vad-probe over
    // corpus/blips AND corpus/commands) — see AGENTS.md "Silence / no-speech behavior".
    // v0.15.6. The VAD artifact is pinned separately in SpeechPresenceDetector: 0.15.5 moved the SDK's
    // default Silero model to v6.2.1 (PR #734, a one-line artifact swap), which FAILS the blips gate —
    // so KeyScribe names the v6.0.0 artifact itself. See AGENTS.md "FluidAudio".
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b"),
    .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    .package(url: "https://github.com/rsperko/speech-swift.git", revision: "96273cd375783531129e5bb97a7ec25a7e717994"),
    // MLX compiles the Qwen3 shaders and runs its inference, so a bump can change transcripts the same
    // way an engine bump can.
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
    // Sparkle is a dependency of every build so its pin lives in the one Package.resolved, but only the
    // KeyScribeSparkle target links it, and only the public app target (App/project.yml) links that.
    // Dev builds, tests, and downstream builds resolve it and never link it.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
]

let package = Package(
    name: "KeyScribe",
    platforms: [.macOS("15.0")],
    // The app's code is a library so an app target built through a standard Xcode project (App/project.yml,
    // or a downstream distribution's own) links one product and inherits every dependency — and its pins —
    // transitively. The executable here is a thin Sparkle-free entry point over it for `swift build`.
    products: [
        .library(name: "KeyScribeKit", targets: ["KeyScribeKit"]),
        .library(name: "KeyScribeApp", targets: ["KeyScribeApp"]),
        .library(name: "KeyScribeSparkle", targets: ["KeyScribeSparkle"]),
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
            dependencies: [
                "KeyScribeKit",
                "ObjCSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/KeyScribe"
        ),
        .target(
            name: "KeyScribeSparkle",
            dependencies: [
                "KeyScribeKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "KeyScribe",
            dependencies: ["KeyScribeApp", "KeyScribeKit"],
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
