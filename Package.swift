// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GrokBotHub",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑：不依赖 AppKit，便于单元测试
        .target(name: "HubCore", path: "Sources/HubCore"),
        .executableTarget(
            name: "GrokBotHub",
            dependencies: ["HubCore"],
            path: "Sources/GrokBotHub",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"], path: "Tests/HubCoreTests"),
    ]
)
