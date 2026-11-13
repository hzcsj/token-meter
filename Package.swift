// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CZstd", path: "Sources/CZstd", exclude: ["README.md"]),
        .executableTarget(
            name: "TokenMeter",
            dependencies: ["CZstd"],
            path: "Sources/TokenMeter"
        ),
        .testTarget(
            name: "TokenMeterTests",
            dependencies: ["TokenMeter"]
        )
    ]
)
