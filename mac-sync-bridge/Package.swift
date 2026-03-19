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
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "BridgeRuntime", targets: ["BridgeRuntime"])
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
        .target(
            name: "BridgeRuntime",
            dependencies: ["BridgeCore", "EventKitAdapter", "HTTPClient", "Persistence"]
        ),
        .executableTarget(
            name: "BridgeCLI",
            dependencies: ["BridgeRuntime"]
        ),
        .executableTarget(
            name: "BridgeApp",
            dependencies: ["BridgeRuntime"]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        ),
        .testTarget(
            name: "BridgeRuntimeTests",
            dependencies: ["BridgeRuntime"]
        )
    ]
)
