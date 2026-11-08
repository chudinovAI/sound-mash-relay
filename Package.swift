// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundMashRelay",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "SoundMashRelay", targets: ["SoundMashRelay"])],
    targets: [
        .executableTarget(name: "SoundMashRelay", path: "Sources"),
        .testTarget(name: "SoundMashRelayTests", dependencies: ["SoundMashRelay"], path: "Tests")
    ]
)
