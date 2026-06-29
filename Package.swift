// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KeyScribe",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/rsperko/FluidAudio.git", revision: "a95ec26ee05f19b5f6e69c62e1d4fae420537730"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/rsperko/argmax-oss-swift.git", revision: "7cc6ea2d321c7610f856be5bcebe337baef7a214"),
        .package(url: "https://github.com/rsperko/speech-swift.git", revision: "96273cd375783531129e5bb97a7ec25a7e717994"),
        .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", revision: "0fb16ccb64252b23b17f87c2a8a61228df9e7ebd"),
    ],
    targets: [
        .target(
            name: "KeyScribeKit",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .target(name: "ObjCSupport"),
        .executableTarget(
            name: "KeyScribe",
            dependencies: [
                "KeyScribeKit",
                "ObjCSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "MoonshineVoice", package: "moonshine-swift"),
            ]
        ),
        .testTarget(
            name: "KeyScribeKitTests",
            dependencies: ["KeyScribeKit"]
        ),
        .testTarget(
            name: "KeyScribeTests",
            dependencies: ["KeyScribe", "KeyScribeKit"]
        ),
    ]
)
