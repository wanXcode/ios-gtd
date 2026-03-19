// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacSyncBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "bridge-cli", targets: ["BridgeCLI"]),
        .library(name: "BridgeModels", targets: ["BridgeModels"]),
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "EventKitAdapter", targets: ["EventKitAdapter"]),
        .library(name: "HTTPClient", targets: ["HTTPClient"]),
        .library(name: "Persistence", targets: ["Persistence"])
    ],
    dependencies: [
        // 后续可加入：
        // .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "BridgeModels",
            dependencies: []
        ),
        .target(
            name: "BridgeCore",
            dependencies: ["BridgeModels", "HTTPClient", "Persistence", "EventKitAdapter"]
        ),
        .target(
            name: "EventKitAdapter",
            dependencies: ["BridgeModels"]
        ),
        .target(
            name: "HTTPClient",
            dependencies: ["BridgeModels"]
        ),
        .target(
            name: "Persistence",
            dependencies: ["BridgeModels"]
        ),
        .executableTarget(
            name: "BridgeCLI",
            dependencies: ["BridgeCore"]
        ),
        .executableTarget(
            name: "BridgeApp",
            dependencies: ["BridgeCore"]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        )
    ]
)
