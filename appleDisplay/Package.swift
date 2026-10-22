// swift-tools-version: 5.9
import PackageDescription
import Foundation

/// macOS 测试实际链接当前 SharedLogic；先用 scripts/test_apple_shared.py 构建 Kotlin 再运行。
/// Xcode 各应用仍按需编译 Swift 源文件，并通过各自构建阶段提供对应平台的框架。
let sharedLogicDirectory = ProcessInfo.processInfo.environment["LOKI_SHARED_LOGIC_FRAMEWORK_DIR"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../sharedLogic/build/bin/macosArm64/debugFramework").standardizedFileURL.path
let sharedSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-F", sharedLogicDirectory], .when(platforms: [.macOS])),
]
let sharedLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-F", sharedLogicDirectory], .when(platforms: [.macOS])),
    .linkedFramework("SharedLogic"),
]

let package = Package(
    name: "AppleDisplay",
    platforms: [.macOS(.v13), .iOS("18.2"), .watchOS("11.0")],
    products: [.library(name: "AppleDisplay", targets: ["AppleDisplay"])],
    targets: [
        .target(name: "AppleDisplay", swiftSettings: sharedSwiftSettings, linkerSettings: sharedLinkerSettings),
        .testTarget(name: "AppleDisplayTests", dependencies: ["AppleDisplay"],
                    swiftSettings: sharedSwiftSettings, linkerSettings: sharedLinkerSettings),
    ]
)
