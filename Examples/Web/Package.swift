// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForceGraphWebDemo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ForceGraphWasm", targets: ["ForceGraphWasm"])],
    dependencies: [.package(name: "ForceGraph", path: "../..")],
    targets: [
        .executableTarget(
            name: "ForceGraphWasm",
            dependencies: [.product(name: "ForceGraph", package: "ForceGraph")],
            swiftSettings: [.enableExperimentalFeature("Extern")]
        )
    ]
)
