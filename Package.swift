// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NgrokMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NgrokMonitor",
            dependencies: [],
            resources: [
                .process("Resources/ngrok-black.png"),
                .process("Resources/ngrok-green.png"),
                .copy("Resources/bundle.plist"),
            ]
        )
    ]
)
