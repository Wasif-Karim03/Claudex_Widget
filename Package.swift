// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudex", targets: ["Claudex"]),
        .library(name: "ClaudexCore", targets: ["ClaudexCore"]),
    ],
    targets: [
        .target(name: "ClaudexCore"),
        .executableTarget(
            name: "Claudex",
            dependencies: ["ClaudexCore"]
        ),
        .testTarget(
            name: "ClaudexCoreTests",
            dependencies: ["ClaudexCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
