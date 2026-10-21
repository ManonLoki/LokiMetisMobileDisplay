// swift-tools-version: 5.9
import PackageDescription

/// 仅用系统Foundation测试iOS App与Widget共同使用的展示快照，不引入第三方依赖。
let package = Package(
    name: "AppleDisplay",
    platforms: [.macOS(.v13), .iOS("18.2")],
    products: [.library(name: "AppleDisplay", targets: ["AppleDisplay"])],
    targets: [.target(name: "AppleDisplay"), .testTarget(name: "AppleDisplayTests", dependencies: ["AppleDisplay"])]
)
