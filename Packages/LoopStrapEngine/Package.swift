// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoopStrapEngine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "LoopStrapEngine", targets: ["LoopStrapEngine"])],
    targets: [
        .target(
            name: "LoopStrapEngine"
        ),
        .testTarget(
            name: "LoopStrapEngineTests",
            dependencies: ["LoopStrapEngine"],
            resources: [.process("Resources")]
        ),
    ]
)
