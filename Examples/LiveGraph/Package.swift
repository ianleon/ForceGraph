// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LiveGraphDemo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "ForceGraph", path: "../..")],
    targets: [.executableTarget(name: "LiveGraphDemo", dependencies: [.product(name: "ForceGraph", package: "ForceGraph")])]
)
