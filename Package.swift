// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sonora",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Sonora", targets: ["Sonora"])],
    targets: [
        .executableTarget(name: "Sonora")
    ]
)
