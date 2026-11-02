// swift-tools-version:5.9
import PackageDescription

// Warnings do compilador quebram o build (junto com o SwiftLint em --strict)
let strict: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "NotchLimits",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchLimits", path: "Sources/NotchLimits", swiftSettings: strict),
        .testTarget(
            name: "NotchLimitsTests",
            dependencies: ["NotchLimits"],
            path: "Tests/NotchLimitsTests",
            swiftSettings: strict
        ),
    ]
)
