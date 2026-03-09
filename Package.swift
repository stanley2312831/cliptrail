// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipTrail",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "cliptrail", targets: ["ClipTrail"])
    ],
    targets: [
        .executableTarget(
            name: "ClipTrail",
            path: "Sources"
        )
    ]
)
