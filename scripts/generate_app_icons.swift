#!/usr/bin/env swift
// Run from the repository root: swift scripts/generate_app_icons.swift
// Uses only the macOS SDK. The desktop logo is preserved in branding/app-icon.png.
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

func write(_ content: String, to path: String) throws {
    let url = root.appendingPathComponent(path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

func render(_ path: String, size: Int, artworkFraction: CGFloat) throws {
    let url = root.appendingPathComponent(path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // noneSkipLast removes the alpha channel required to be absent from Apple app icons.
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
    // Blend only the original logo's empty outer border into the extended dark
    // background, so adding safe margins does not leave a visible square seam.
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
    // A 5% inset protects the top and bottom points under the system's round mask.
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
// Adaptive icons are 108 dp with a central 72 dp viewport. A 60% source image
// becomes the same 90% artwork scale in that viewport and stays inside the safe circle.
try render("\(resources)/drawable-nodpi/ic_launcher_foreground.png", size: 432, artworkFraction: 0.60)
