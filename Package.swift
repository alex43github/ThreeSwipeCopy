// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThreeSwipeCopy",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ThreeSwipeCopy",
            path: "Sources/ThreeSwipeCopy"
        )
    ]
)
