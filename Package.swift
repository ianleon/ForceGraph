// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForceGraph",
    // ForceGraphView needs iOS 17, macOS 14 or visionOS 1. ForceLayout also builds for
    // tvOS 16 and watchOS 9, the floor for Duration and ContinuousClock.
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v1), .tvOS(.v16), .watchOS(.v9)],
    products: [
        .library(name: "ForceGraph", targets: ["ForceGraph"]),
    ],
    targets: [
        .target(name: "ForceGraph"),
        .testTarget(name: "ForceGraphTests", dependencies: ["ForceGraph"]),
    ]
)
