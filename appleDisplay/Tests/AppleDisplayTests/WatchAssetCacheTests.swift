import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AppleDisplay

final class WatchAssetCacheTests: XCTestCase {
    private let transfer = "32345678-1234-4abc-8def-123456789abc"

    private func encoded(type: String, mime: String, frames: Int = 2, size: Int = 8) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
        let dictionary = mime == "image/gif" ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loopKey = mime == "image/gif" ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        let delayKey = mime == "image/gif" ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
        CGImageDestinationSetProperties(destination, [dictionary: [loopKey: 2]] as CFDictionary)
        for index in 0..<frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: index.isMultiple(of: 2) ? 1 : 0, green: 0,
                blue: index.isMultiple(of: 2) ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [dictionary: [delayKey: index == 0 ? 0.05 : 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 走Watch真实分块校验后再从命中的私有缓存解码，不绕过传输哈希。
    private func committed(_ data: Data, mime: String) throws -> (WatchAssetCache, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let cache = try WatchAssetCache(directory: folder)
        let descriptor = LanDisplaySnapshot.Asset(hash: WatchProtocol.hash(data), mime: mime, length: UInt64(data.count))
        try cache.begin(descriptor, id: transfer)
        var offset = 0
        while offset < data.count {
            let end = min(offset + WatchProtocol.chunkSize, data.count)
            let result = try cache.accept(id: transfer, offset: UInt64(offset), data: data.subdata(in: offset..<end))
            XCTAssertEqual(result.0, UInt64(end))
            if end < data.count { XCTAssertNil(result.1) }
            offset = end
        }
        return (cache, try XCTUnwrap(cache.cached(descriptor)))
    }

    func test_cached_watch_gif_and_apng_preserve_frames_timings_and_finite_loops() throws {
        for (type, mime) in [("com.compuserve.gif", "image/gif"), ("public.png", "image/png")] {
            let (cache, path) = try committed(encoded(type: type, mime: mime), mime: mime)
            let asset = try cache.image(path, mime: mime)
            XCTAssertEqual(asset.frames.count, 2)
            XCTAssertEqual(asset.frameDurations[0], 0.05, accuracy: 0.001)
            XCTAssertEqual(asset.frameDurations[1], 0.2, accuracy: 0.001)
            XCTAssertEqual(asset.playCount, mime == "image/gif" ? 3 : 2)
            XCTAssertEqual(asset.frameIndex(at: 0.01), 0)
            XCTAssertEqual(asset.frameIndex(at: 0.08), 1)
            XCTAssertEqual(asset.frameIndex(at: 0.26), 0)
            XCTAssertEqual(asset.frameIndex(at: asset.duration * Double(asset.playCount)), 1)
            XCTAssertNotEqual(asset.frames[0].dataProvider?.data as Data?, asset.frames[1].dataProvider?.data as Data?)
        }
    }

    func test_watch_image_pixel_and_total_animation_memory_are_bounded_without_dropping_frames() throws {
        let mime = "image/gif"
        let (staticCache, staticPath) = try committed(encoded(type: "com.compuserve.gif", mime: mime, frames: 1, size: 512), mime: mime)
        let still = try staticCache.image(staticPath, mime: mime)
        XCTAssertEqual(still.frames.count, 1)
        XCTAssertEqual(still.frames[0].width, 256)
        XCTAssertEqual(still.frames[0].height, 256)

        for frameCount in [9, 32] {
            let (cache, path) = try committed(encoded(type: "com.compuserve.gif", mime: mime, frames: frameCount, size: 512), mime: mime)
            let asset = try cache.image(path, mime: mime)
            XCTAssertEqual(asset.frames.count, frameCount)
            XCTAssertLessThanOrEqual(asset.decodedByteCount, 2 * 1024 * 1024)
            XCTAssertLessThan(asset.frames[0].width, 256)
            XCTAssertTrue(asset.frames.allSatisfy { $0.width <= 256 && $0.height <= 256 })
            XCTAssertEqual(asset.frameDurations[0], 0.05, accuracy: 0.001)
            XCTAssertTrue(asset.frameDurations.dropFirst().allSatisfy { abs($0 - 0.2) < 0.001 })
        }
    }
}
