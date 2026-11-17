// swift-tools-version: 5.9
import PackageDescription

// Offline replay of a StrapCapture JSONL offload into a COPY of a Loop backup database.
// No BLE, no ack: rebuilds HISTORY_END chunks exactly like the app's Backfiller and commits them
// through WhoopStore.commitHistoricalChunk (ON CONFLICT DO NOTHING => idempotent).
let package = Package(
    name: "StrapReplay",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/WhoopProtocol"),
        .package(path: "../../Packages/WhoopStore"),
    ],
    targets: [
        .executableTarget(
            name: "strapreplay",
            dependencies: [
                .product(name: "WhoopProtocol", package: "WhoopProtocol"),
                .product(name: "WhoopStore", package: "WhoopStore"),
            ]
        )
    ]
)
