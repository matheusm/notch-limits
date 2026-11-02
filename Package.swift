// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchLimits",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchLimits", path: "Sources/NotchLimits"),
        .testTarget(name: "NotchLimitsTests", dependencies: ["NotchLimits"], path: "Tests/NotchLimitsTests"),
    ]
)
