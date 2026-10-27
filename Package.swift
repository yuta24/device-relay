// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "device-relay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "relay", targets: ["relay"])
    ],
    targets: [
        .executableTarget(name: "relay"),
        .testTarget(name: "relayTests", dependencies: ["relay"])
    ]
)
