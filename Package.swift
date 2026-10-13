// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlyoverPitchLab",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FlyoverPitchLab", targets: ["FlyoverPitchLab"])
    ],
    targets: [
        .executableTarget(name: "FlyoverPitchLab")
    ]
)
