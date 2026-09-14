// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HealthBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HealthBridgeCore", targets: ["HealthBridgeCore"]),
        .executable(name: "HealthBridge", targets: ["HealthBridge"]),
    ],
    targets: [
        // Thin C shim over libproc so the server can map a loopback TCP peer
        // back to the process that owns the socket.
        .target(
            name: "CLibProc",
            path: "Sources/CLibProc",
            linkerSettings: [.linkedFramework("HealthKit")]
        ),
        .target(
            name: "HealthBridgeCore",
            dependencies: ["CLibProc"],
            path: "Sources/HealthBridgeCore",
            linkerSettings: [
                .linkedFramework("HealthKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "HealthBridge",
            dependencies: ["HealthBridgeCore"],
            path: "Sources/HealthBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "HealthBridgeCoreTests",
            dependencies: ["HealthBridgeCore"],
            path: "Tests/HealthBridgeCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
