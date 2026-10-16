// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "am",
    platforms: [.macOS(.v13)],
    targets: [
        // No external dependencies: configuration is JSON (Codable), argument
        // parsing and the interactive menu are written here.
        .executableTarget(name: "am", path: "Sources/am"),
        .testTarget(name: "amTests", dependencies: ["am"], path: "Tests/amTests"),
    ]
)
