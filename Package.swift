// swift-tools-version:6.0
import PackageDescription

// Layering (one-way): SwitchboardCore <- switchboard (CLI), switchboard-launch, SwitchboardApp.
// All logic lives in SwitchboardCore; the executables are thin. See docs/architecture.md.
let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitchboardCore", targets: ["SwitchboardCore"]),
        .executable(name: "switchboard", targets: ["switchboard"]),
        .executable(name: "switchboard-launch", targets: ["switchboard-launch"]),
        .executable(name: "SwitchboardApp", targets: ["SwitchboardApp"]),
    ],
    targets: [
        .target(
            name: "SwitchboardCore",
            path: "Sources/SwitchboardCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "switchboard",
            dependencies: ["SwitchboardCore"],
            path: "Sources/switchboard"
        ),
        .executableTarget(
            name: "switchboard-launch",
            dependencies: ["SwitchboardCore"],
            path: "Sources/switchboard-launch"
        ),
        .executableTarget(
            name: "SwitchboardApp",
            dependencies: ["SwitchboardCore"],
            path: "Sources/SwitchboardApp"
        ),
        .testTarget(
            name: "SwitchboardCoreTests",
            dependencies: ["SwitchboardCore"],
            path: "Tests/SwitchboardCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
