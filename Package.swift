// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ribbon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ribbon", resources: [
            .copy("Resources/Audio"),
            .copy("Resources/Preview")
        ])
    ]
)
