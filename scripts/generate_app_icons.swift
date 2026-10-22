#!/usr/bin/env swift
// 在仓库根目录运行：swift scripts/generate_app_icons.swift，仅依赖 macOS SDK。
// 读取 branding/app-icon.png 的桌面品牌原图，覆盖下列各端图标与资源清单，不修改原图。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let files = FileManager.default
let sourceURL = root.appendingPathComponent("branding/app-icon.png")
guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      source.width == 1024, source.height == 1024 else {
    fatalError("Expected the 1024 × 1024 desktop logo at branding/app-icon.png")
}

/// 创建父目录，以 UTF-8 原子写入相对仓库根目录的资源清单。
func write(_ content: String, to path: String) throws {
    let url = root.appendingPathComponent(path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

/// 将原图居中缩放到指定比例，补齐深色边缘，写出指定像素尺寸的不透明 PNG。
func render(_ path: String, size: Int, artworkFraction: CGFloat) throws {
    let url = root.appendingPathComponent(path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // noneSkipLast 让所有生成图标都使用不含透明通道的画布。
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        fatalError("Could not create the icon bitmap")
    }
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [28 / 255, 29 / 255, 30 / 255, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    let side = CGFloat(size) * artworkFraction
    let inset = (CGFloat(size) - side) / 2
    context.draw(source, in: CGRect(x: inset, y: inset, width: side, height: side))
    // 只将原图外围 2.5% 的留白混入深色底，避免扩展边距后露出方形接缝。
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let background: [CGFloat] = [28, 29, 30]
    let feather = side * 0.025
    for y in 0..<size {
        for x in 0..<size {
            let edgeDistance = min(CGFloat(x) + 0.5 - inset, CGFloat(y) + 0.5 - inset,
                                   inset + side - CGFloat(x) - 0.5, inset + side - CGFloat(y) - 0.5)
            guard edgeDistance >= 0, edgeDistance < feather else { continue }
            let t = edgeDistance / feather
            let weight = t * t * (3 - 2 * t)
            let offset = (y * size + x) * 4
            for channel in 0..<3 {
                pixels[offset + channel] = UInt8((background[channel] * (1 - weight)
                    + CGFloat(pixels[offset + channel]) * weight).rounded())
            }
        }
    }
    guard let bitmap = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create \(path)")
    }
    CGImageDestinationAddImage(destination, bitmap, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(path)") }
    print("\(path): \(size) × \(size), opaque")
}

let appleIcon = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "%@",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
for (directory, platform) in [
    ("iosApp/iosApp/Assets.xcassets/AppIcon.appiconset", "ios"),
    ("iosApp/LokiMetrisWatch/Assets.xcassets/AppIcon.appiconset", "watchos")
] {
    // 原图占画布 90%，四边各留 5%，减少系统裁切时对上下尖角的影响。
    try render("\(directory)/AppIcon.png", size: 1024, artworkFraction: 0.90)
    try write(String(format: appleIcon, platform), to: "\(directory)/Contents.json")
}
try write("{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n",
          to: "iosApp/LokiMetrisWatch/Assets.xcassets/Contents.json")

let resources = "androidApp/src/main/res"
for (density, pixels) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    try render("\(resources)/mipmap-\(density)/ic_launcher.png", size: pixels, artworkFraction: 0.90)
    try render("\(resources)/mipmap-\(density)/ic_launcher_round.png", size: pixels, artworkFraction: 0.90)
}
// 自适应图标前景按 108 dp 画布、中心 72 dp 视口计算；原图占全画布 60%，
// 相当于中心视口的 90%，与上述图标保持相近的可见比例。
try render("\(resources)/drawable-nodpi/ic_launcher_foreground.png", size: 432, artworkFraction: 0.60)
