// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OST",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OSTCore", targets: ["OSTCore"]),
        .library(name: "OSTPlatform", targets: ["OSTPlatform"]),
        .library(name: "OSTMLX", targets: ["OSTMLX"]),
        .library(name: "OSTDownloader", targets: ["OSTDownloader"]),
        .executable(name: "OSTApp", targets: ["OSTApp"]),
        .executable(name: "OSTModelDownloaderXPC", targets: ["OSTModelDownloaderXPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
    ],
    targets: [
        .target(
            name: "OSTCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "OSTPlatform",
            dependencies: ["OSTCore"]
        ),
        .target(
            name: "OSTMLX",
            dependencies: [
                "OSTCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            ]
        ),
        .target(
            name: "OSTDownloader",
            dependencies: ["OSTCore"]
        ),
        .executableTarget(
            name: "OSTApp",
            dependencies: ["OSTCore", "OSTPlatform", "OSTMLX"],
            resources: [
                .process("Assets.xcassets"),
                .process("en.lproj"),
                .process("zh-Hans.lproj"),
                .process("ja.lproj"),
                .process("ko.lproj"),
            ]
        ),
        .executableTarget(
            name: "OSTModelDownloaderXPC",
            dependencies: ["OSTCore", "OSTDownloader"]
        ),
        .testTarget(
            name: "OSTCoreTests",
            dependencies: ["OSTCore"]
        ),
        .testTarget(
            name: "OSTPlatformTests",
            dependencies: ["OSTCore", "OSTPlatform"]
        ),
        .testTarget(
            name: "OSTDownloaderTests",
            dependencies: ["OSTCore", "OSTDownloader"]
        ),
    ]
)
