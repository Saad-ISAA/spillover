// swift-tools-version:6.0
import PackageDescription

// Layering (one-way): SpilloverCore <- spillover (CLI), spillover-launch, SpilloverApp.
// All logic lives in SpilloverCore; the executables are thin. See docs/architecture.md.
let package = Package(
    name: "Spillover",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpilloverCore", targets: ["SpilloverCore"]),
        .executable(name: "spillover", targets: ["spillover"]),
        .executable(name: "spillover-launch", targets: ["spillover-launch"]),
        .executable(name: "SpilloverApp", targets: ["SpilloverApp"]),
    ],
    targets: [
        .target(
            name: "SpilloverCore",
            path: "Sources/SpilloverCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "spillover",
            dependencies: ["SpilloverCore"],
            path: "Sources/spillover"
        ),
        .executableTarget(
            name: "spillover-launch",
            dependencies: ["SpilloverCore"],
            path: "Sources/spillover-launch"
        ),
        .executableTarget(
            name: "SpilloverApp",
            dependencies: ["SpilloverCore"],
            path: "Sources/SpilloverApp"
        ),
        .testTarget(
            name: "SpilloverCoreTests",
            dependencies: ["SpilloverCore"],
            path: "Tests/SpilloverCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
