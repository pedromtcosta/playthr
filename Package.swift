// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Playthr",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Playthr", targets: ["Playthr"])],
    targets: [
        .target(name: "PlaythrCore"),
        .executableTarget(name: "Playthr", dependencies: ["PlaythrCore"]),
        .testTarget(name: "PlaythrCoreTests", dependencies: ["PlaythrCore"])
    ],
    swiftLanguageModes: [.v5]
)
