// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EP2350Core",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EP2350Core", targets: ["EP2350Core"])],
    targets: [
        .target(name: "EP2350Core"),
        .testTarget(name: "EP2350CoreTests", dependencies: ["EP2350Core"], resources: [.copy("Fixtures")])
    ]
)
