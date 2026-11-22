// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitMenuBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GitMenuBar", targets: ["GitMenuBar"])],
    targets: [
        .executableTarget(name: "GitMenuBar"),
        .testTarget(name: "GitMenuBarTests", dependencies: ["GitMenuBar"])
    ]
)
