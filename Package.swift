// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Sage",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SageCore", targets: ["SageCore"]),
        .executable(name: "Sage", targets: ["Sage"]),
    ],
    dependencies: [
        .package(path: "../iUX-MacOS"),
    ],
    targets: [
        .target(
            name: "SageCore",
            dependencies: ["iUX-MacOS"],
            path: "Sources/SageCore"
        ),
        .executableTarget(
            name: "Sage",
            dependencies: ["SageCore"],
            path: "Sources/Sage"
        ),
        .testTarget(
            name: "SageCoreTests",
            dependencies: ["SageCore"],
            path: "Tests/SageCoreTests"
        ),
    ]
)
