// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForceGraph",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v1)],
    products: [
        .library(name: "ForceGraph", targets: ["ForceGraph"]),
    ],
    targets: [
        .target(name: "ForceGraph"),
        .testTarget(name: "ForceGraphTests", dependencies: ["ForceGraph"]),
    ]
)
