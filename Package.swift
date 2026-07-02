// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VeniceVideoCreator",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VeniceVideoCreator", targets: ["VeniceVideoCreator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
    ],
    targets: [
        .executableTarget(
            name: "VeniceVideoCreator",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Lottie", package: "lottie-ios"),
            ],
            path: "Sources/VeniceVideoCreator",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
            ],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/palmier-pro.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Changelog"),
            ],
            plugins: ["MetalCIKernelPlugin"]
        ),
        .plugin(name: "MetalCIKernelPlugin", capability: .buildTool()),
        .testTarget(
            name: "VeniceVideoCreatorTests",
            dependencies: ["VeniceVideoCreator"],
            path: "Tests/VeniceVideoCreatorTests"
        ),
    ]
)
