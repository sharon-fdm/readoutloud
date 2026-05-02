// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadAloud",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ReadAloud",
            targets: ["ReadAloud"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ReadAloud"
        )
    ]
)
