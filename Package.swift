// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PureClipboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PureClipboard", targets: ["PureClipboard"]),
    ],
    targets: [
        .target(name: "PureClipboardCore"),
        .executableTarget(
            name: "PureClipboard",
            dependencies: ["PureClipboardCore"]
        ),
        .testTarget(
            name: "PureClipboardCoreTests",
            dependencies: ["PureClipboardCore"]
        ),
    ]
)
