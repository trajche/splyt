// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SplytCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SplytCore", targets: ["SplytCore"])],
    targets: [
        .target(name: "SplytCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "splyt-probe",
            dependencies: ["SplytCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "splyt-socks",
            dependencies: ["SplytCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SplytCoreTests",
            dependencies: ["SplytCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
