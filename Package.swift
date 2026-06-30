// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GPTUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GPTUsageBar", targets: ["GPTUsageBarApp"])
    ],
    targets: [
        .executableTarget(
            name: "GPTUsageBarApp",
            path: "Sources/GPTUsageBarApp"
        )
    ]
)
