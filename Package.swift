// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BrainBuilder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BrainBuilder", targets: ["BrainBuilder"])
    ],
    targets: [
        .executableTarget(
            name: "BrainBuilder",
            path: "Sources/BrainBuilder"
        ),
        .testTarget(
            name: "BrainBuilderTests",
            dependencies: ["BrainBuilder"],
            path: "Tests/BrainBuilderTests"
        )
    ]
)
