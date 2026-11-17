// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoopReplay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "loop-replay", targets: ["loop-replay"]), .executable(name: "loop-daily-replay", targets: ["loop-daily-replay"])],
    dependencies: [.package(path: "../../Packages/LoopStrapEngine"), .package(path: "../../Packages/WhoopStore"), .package(path: "../../Packages/WhoopProtocol")],
    targets: [
        .systemLibrary(name: "ReplaySQLite"),
        .target(name: "ReplayCore", dependencies: ["ReplaySQLite", .product(name: "LoopStrapEngine", package: "LoopStrapEngine")]),
        .executableTarget(name: "loop-replay", dependencies: ["ReplayCore"]),
        .executableTarget(name: "loop-daily-replay", dependencies: ["ReplayCore", "ReplaySQLite", .product(name: "WhoopStore", package: "WhoopStore"), .product(name: "WhoopProtocol", package: "WhoopProtocol"), .product(name: "LoopStrapEngine", package: "LoopStrapEngine")]),
        .target(name: "Loop", dependencies: [.product(name: "WhoopStore", package: "WhoopStore"), .product(name: "WhoopProtocol", package: "WhoopProtocol"), .product(name: "LoopStrapEngine", package: "LoopStrapEngine")]),
        .testTarget(name: "AppIntegrationTests", dependencies: ["Loop", .product(name: "WhoopStore", package: "WhoopStore"), .product(name: "WhoopProtocol", package: "WhoopProtocol")]),
        .testTarget(name: "ReplayCoreTests", dependencies: ["ReplayCore", "ReplaySQLite"])
    ]
)
