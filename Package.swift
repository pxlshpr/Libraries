// swift-tools-version: 5.9
// The repo as a Swift package, so ThinkingOrbsKit can be added by this repo's URL. Swift
// Package Manager only reads a manifest at a repo's root; the kit's own manifest
// (packages/thinking-orbs/ports/ios/ThinkingOrbsKit/Package.swift) stays for working in the
// kit by itself (`swift test`, `snapshot.sh`).
import PackageDescription

let kit = "packages/thinking-orbs/ports/ios/ThinkingOrbsKit"

let package = Package(
    name: "Libraries",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThinkingOrbsKit", targets: ["ThinkingOrbsKit"])
    ],
    targets: [
        .target(name: "ThinkingOrbsKit", path: "\(kit)/Sources/ThinkingOrbsKit"),
        .testTarget(
            name: "ThinkingOrbsKitTests",
            dependencies: ["ThinkingOrbsKit"],
            path: "\(kit)/Tests/ThinkingOrbsKitTests"
        )
    ]
)
