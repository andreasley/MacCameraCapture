// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacCameraCapture",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MacCameraCapture", targets: ["MacCameraCapture"]),
    ],
    targets: [
        .target(
            name: "MacCameraCapture"
        ),
        .executableTarget(
            name: "MacCameraCaptureTester",
            dependencies: ["MacCameraCapture"]
        )
    ]
)
