// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AIBarCore", targets: ["AIBarCore"]),
        .executable(name: "aibar-macos", targets: ["aibar-macos"])
    ],
    targets: [
        .target(
            name: "AIBarCore",
            path: "Sources/AIBarCore"
        ),
        .executableTarget(
            name: "aibar-macos",
            dependencies: ["AIBarCore"],
            path: "Sources/aibar-macos"
        ),
        .testTarget(
            name: "AIBarCoreTests",
            dependencies: ["AIBarCore"],
            path: "Tests/AIBarCoreTests"
        )
    ]
)
