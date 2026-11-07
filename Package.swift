// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "device-relay",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "relay", targets: ["Relay"])
    ],
    targets: [
        .executableTarget(name: "Relay"),
        .testTarget(name: "RelayTests", dependencies: ["Relay"])
    ]
)
