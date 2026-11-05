// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "device-relay",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "relay", targets: ["relay"])
    ],
    targets: [
        .executableTarget(name: "relay"),
        .testTarget(name: "relayTests", dependencies: ["relay"])
    ]
)
