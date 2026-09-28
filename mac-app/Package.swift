// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XGecuBufferCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "XGecuBufferCore", targets: ["XGecuBufferCore"])],
    targets: [
        .target(name: "XGecuBufferCore", path: "Shared"),
        .testTarget(name: "XGecuBufferCoreTests", dependencies: ["XGecuBufferCore"], path: "Tests"),
    ]
)
