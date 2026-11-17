// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Absolute path of this package, so the linker finds Info.plist regardless of the cwd swift build uses.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "StrapCapture",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/WhoopProtocol")
    ],
    targets: [
        .executableTarget(
            name: "strapcapture",
            dependencies: [.product(name: "WhoopProtocol", package: "WhoopProtocol")],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist in the Mach-O (__TEXT,__info_plist) so TCC finds
                // NSBluetoothAlwaysUsageDescription; without it macOS kills the process on first CB use.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Sources/strapcapture/Info.plist",
                ])
            ]
        )
    ]
)
