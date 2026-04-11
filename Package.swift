// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZXCropper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ZXCropper",
            targets: ["ZXCropper"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ZXCropper",
            path: "Sources/ZXCropper"
        )
    ]
)
