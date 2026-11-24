// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MuseFrame",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MuseFrame", targets: ["MuseFrame"])],
    targets: [
        .executableTarget(name: "MuseFrame", path: "MuseFrame",
            exclude: ["App/Info.plist", "App/MuseFrame.entitlements", "Assets.xcassets"],
            resources: [.process("Data/SeedData"), .process("Resources")]),
        .testTarget(name: "MuseFrameTests", dependencies: ["MuseFrame"], path: "Tests/MuseFrameTests")
    ],
    swiftLanguageModes: [.v6]
)
