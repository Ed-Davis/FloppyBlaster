// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FloppyBlaster",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "FloppyBlasterCore",
            path: "Sources/FloppyBlasterCore"
        ),
        .executableTarget(
            name: "FloppyBlaster",
            dependencies: ["FloppyBlasterCore"],
            path: "Sources/FloppyBlaster",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "FloppyBlasterCoreTests",
            dependencies: ["FloppyBlasterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
