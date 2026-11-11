// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glow",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "Glow", path: "Sources/Glow")],
    swiftLanguageModes: [.v5]
)
