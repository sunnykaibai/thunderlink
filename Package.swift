// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ThunderLink",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ThunderLink", targets: ["ThunderLink"])
    ],
    targets: [
        .executableTarget(
            name: "ThunderLink",
            path: "Sources/ThunderLink"
        ),
        .testTarget(
            name: "ThunderLinkTests",
            dependencies: ["ThunderLink"],
            path: "Tests/ThunderLinkTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
