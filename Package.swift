// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowLane",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WindowLane", targets: ["WindowLane"])],
    targets: [
        .target(name: "WindowLaneCore"),
        .executableTarget(name: "WindowLane", dependencies: ["WindowLaneCore"]),
        .testTarget(name: "WindowLaneCoreTests", dependencies: ["WindowLaneCore"])
    ],
    swiftLanguageVersions: [.v5]
)
