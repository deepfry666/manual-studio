// swift-tools-version: 6.0
import PackageDescription

/// 核心逻辑（生图网关、大模型、流水线、排版、批量、导出）：不依赖界面，`swift test` 直接测试。
/// App 界面在 ../App/ 里，用 ../ManualStudio.xcodeproj 构建。
let package = Package(
    name: "ManualStudio",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
    ],
    targets: [
        .target(name: "StudioCore", path: "Sources/StudioCore"),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"], path: "Tests/StudioCoreTests"),
    ]
)
