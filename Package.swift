// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PureClipboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PureClipboard", targets: ["PureClipboard"]),
        .executable(name: "pureclipboard-hook", targets: ["pureclipboard-hook"]),
    ],
    targets: [
        .target(name: "PureClipboardCore"),
        .executableTarget(
            name: "PureClipboard",
            dependencies: ["PureClipboardCore"]
        ),
        .executableTarget(
            name: "pureclipboard-hook",
            dependencies: ["PureClipboardCore"]
        ),
        .testTarget(
            name: "PureClipboardCoreTests",
            dependencies: ["PureClipboardCore"]
        ),
    ]
)
