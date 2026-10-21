import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AppleDisplay

final class LanImageAssetTests: XCTestCase {
    private func image(_ red: CGFloat, _ blue: CGFloat, size: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try XCTUnwrap(context.makeImage())
    }

    private func encoded(_ type: String, mime: String, animated: Bool = false, loops: Int = 0) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, animated ? 2 : 1, nil))
        let dictionary = mime == "image/gif" ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loopKey = mime == "image/gif" ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        let delayKey = mime == "image/gif" ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
        if animated { CGImageDestinationSetProperties(destination, [dictionary: [loopKey: loops]] as CFDictionary) }
        CGImageDestinationAddImage(destination, try image(1, 0), [dictionary: [delayKey: 0.05]] as CFDictionary)
        if animated { CGImageDestinationAddImage(destination, try image(0, 1), [dictionary: [delayKey: 0.2]] as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 自包含1×1 WebP位流；容器按RIFF规范构造，两帧分别使用lossless/lossy像素。
    private func webp(animated: Bool) -> Data {
        let still = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAfQ//73v/+BiOh/AAA=")!
        guard animated else { return still }
        func little(_ value: Int, count: Int) -> Data {
            Data((0..<count).map { UInt8((value >> ($0 * 8)) & 255) })
        }
        func chunk(_ tag: String, _ body: Data) -> Data {
            Data(tag.utf8) + little(body.count, count: 4) + body + Data(repeating: 0, count: body.count % 2)
        }
        let second = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
        var body = Data("WEBP".utf8)
        body += chunk("VP8X", Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        body += chunk("ANIM", Data([0, 0, 0, 0, 2, 0]))
        for (delay, source) in [(50, still), (200, second)] {
            let frame = Data(repeating: 0, count: 12) + little(delay, count: 3) + Data([2]) + source.dropFirst(12)
            body += chunk("ANMF", frame)
        }
        return Data("RIFF".utf8) + little(body.count, count: 4) + body
    }

    func test_static_and_animated_webp_decode_with_native_imageio() throws {
        let still = try LanImageAsset.decode(webp(animated: false), mime: "image/webp")
        XCTAssertEqual(still.frames.count, 1)
        let animated = try LanImageAsset.decode(webp(animated: true), mime: "image/webp")
        XCTAssertEqual(animated.frames.count, 2)
        XCTAssertEqual(animated.frameDurations[0], 0.05, accuracy: 0.001)
        XCTAssertEqual(animated.frameDurations[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(animated.playCount, 2)
        XCTAssertEqual(animated.frameIndex(at: 0.08), 1)
        XCTAssertEqual(animated.frameIndex(at: 0.26), 0)
        XCTAssertEqual(animated.frameIndex(at: 0.6), 1)
        XCTAssertNotEqual(animated.frames[0].dataProvider?.data as Data?, animated.frames[1].dataProvider?.data as Data?)
    }

    func test_bmp_png_and_jpeg_decode_as_static_images() throws {
        for (type, mime) in [("com.microsoft.bmp", "image/bmp"), ("public.png", "image/png"), ("public.jpeg", "image/jpeg")] {
            let value = try LanImageAsset.decode(encoded(type, mime: mime), mime: mime)
            XCTAssertEqual(value.frames.count, 1)
            XCTAssertFalse(value.isAnimated)
            XCTAssertEqual(value.frames[0].width, 8)
            XCTAssertLessThanOrEqual(value.decodedByteCount, 8 * 1024 * 1024)
        }
    }

    func test_gif_and_animated_png_keep_all_frames_and_original_delays() throws {
        for (type, mime) in [("com.compuserve.gif", "image/gif"), ("public.png", "image/png")] {
            let value = try LanImageAsset.decode(encoded(type, mime: mime, animated: true), mime: mime)
            XCTAssertEqual(value.frames.count, 2)
            XCTAssertTrue(value.isAnimated)
            XCTAssertEqual(value.frameDurations[0], 0.05, accuracy: 0.001)
            XCTAssertEqual(value.frameDurations[1], 0.2, accuracy: 0.001)
            XCTAssertEqual(value.duration, 0.25, accuracy: 0.001)
            XCTAssertEqual(value.frameIndex(at: 0.01), 0)
            XCTAssertEqual(value.frameIndex(at: 0.08), 1)
            XCTAssertEqual(value.frameIndex(at: 0.26), 0)
            XCTAssertEqual(value.playCount, 0)
            XCTAssertNotEqual(value.frames[0].dataProvider?.data as Data?, value.frames[1].dataProvider?.data as Data?)
        }
    }

    func test_finite_animation_stops_at_the_last_frame() throws {
        let value = try LanImageAsset.decode(encoded("public.png", mime: "image/png", animated: true, loops: 2), mime: "image/png")
        XCTAssertEqual(value.playCount, 2)
        XCTAssertEqual(value.frameIndex(at: 0.26), 0)
        XCTAssertEqual(value.frameIndex(at: 0.6), 1)
    }

    func test_frame_count_pixels_bytes_and_format_are_bounded() throws {
        let data = try encoded("com.compuserve.gif", mime: "image/gif", animated: true)
        var limits = LanImageAsset.Limits(); limits.maxFrames = 1
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/gif", limits: limits))
        limits = .init(); limits.maxSourcePixels = 1
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/gif", limits: limits))
        limits = .init(); limits.maxEncodedBytes = data.count - 1
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/gif", limits: limits))
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/png"))
        XCTAssertThrowsError(try LanImageAsset.decode(Data("not an image".utf8), mime: "image/gif"))
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/tiff"))
    }

    func test_cached_file_decodes_but_symlink_and_truncated_animation_are_rejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("verified-image"), link = folder.appendingPathComponent("symlink")
        let data = try encoded("com.compuserve.gif", mime: "image/gif", animated: true)
        try data.write(to: file)
        XCTAssertEqual(try LanImageAsset.decode(contentsOf: file, mime: "image/gif").frames.count, 2)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try LanImageAsset.decode(contentsOf: link, mime: "image/gif"))
        XCTAssertThrowsError(try LanImageAsset.decode(Data(data.prefix(data.count / 2)), mime: "image/gif"))
    }

    func test_decoded_budget_downsamples_without_dropping_animation_frames() throws {
        let data = try encoded("com.compuserve.gif", mime: "image/gif", animated: true)
        var limits = LanImageAsset.Limits(); limits.maxDecodedBytes = 128
        let value = try LanImageAsset.decode(data, mime: "image/gif", limits: limits)
        XCTAssertEqual(value.frames.count, 2)
        XCTAssertLessThanOrEqual(value.decodedByteCount, limits.maxDecodedBytes)
        XCTAssertLessThan(value.frames[0].width, 8)
    }
}
