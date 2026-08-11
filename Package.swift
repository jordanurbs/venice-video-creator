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
                .copy("Resources/MCPB/venice-video-creator.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Changelog"),
                .copy("Resources/Capabilities"),
            ],
            swiftSettings: [
                // Swift 6.3.2/6.3.3 runtime regression: the dynamic executor
                // check emitted on @MainActor @objc thunks can build a bogus
                // SerialExecutorRef and SIGSEGV in _checkExpectedExecutor /
                // swift_getObjectType BEFORE the method body runs — observed
                // 2026-08-06 from two unrelated main-thread call sites
                // (ThinkingDots.body, TimelineHeaderView.isFlipped via
                // NSToolTipManager). Both were genuinely on the main thread,
                // so the trap is a false positive. Strip the dynamic checks
                // until the toolchain fix ships, then remove this flag.
                .unsafeFlags(["-disable-dynamic-actor-isolation"])
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
