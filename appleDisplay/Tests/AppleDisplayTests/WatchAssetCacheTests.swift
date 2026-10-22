import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AppleDisplay

final class WatchAssetCacheTests: XCTestCase {
    private let transfer = "32345678-1234-4abc-8def-123456789abc"

    /// 走Watch真实分块校验后再从命中的私有缓存解码，不绕过传输哈希。
    private func committed(_ data: Data, mime: String) throws -> (LanDisplaySnapshot.Asset, URL) {
        let cache = try WatchAssetCache(directory: temporaryFolder())
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
        return (descriptor, try XCTUnwrap(cache.cached(descriptor)))
    }

    func test_cached_watch_gif_and_apng_preserve_frames_timings_and_finite_loops() throws {
        for (type, mime) in [("com.compuserve.gif", "image/gif"), ("public.png", "image/png")] {
            let (descriptor, path) = try committed(TestImages.encoded(type, mime: mime, frames: 2, loops: 2), mime: mime)
            let asset = try WatchAssetCache.image(path, asset: descriptor)
            XCTAssertEqual(asset.id, descriptor.hash)
            XCTAssertEqual(try WatchAssetCache.image(path, asset: descriptor).id, asset.id)
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
        let (staticDescriptor, staticPath) = try committed(TestImages.encoded("com.compuserve.gif", mime: mime, size: 512, loops: 2), mime: mime)
        let still = try WatchAssetCache.image(staticPath, asset: staticDescriptor)
        XCTAssertEqual(still.frames.count, 1)
        XCTAssertEqual(still.frames[0].width, 256)
        XCTAssertEqual(still.frames[0].height, 256)

        for frameCount in [9, 32] {
            let (descriptor, path) = try committed(TestImages.encoded("com.compuserve.gif", mime: mime, frames: frameCount, size: 512, loops: 2), mime: mime)
            let asset = try WatchAssetCache.image(path, asset: descriptor)
            XCTAssertEqual(asset.frames.count, frameCount)
            XCTAssertLessThanOrEqual(asset.decodedByteCount, 2 * 1024 * 1024)
            XCTAssertLessThan(asset.frames[0].width, 256)
            XCTAssertTrue(asset.frames.allSatisfy { $0.width <= 256 && $0.height <= 256 })
            XCTAssertEqual(asset.frameDurations[0], 0.05, accuracy: 0.001)
            XCTAssertTrue(asset.frameDurations.dropFirst().allSatisfy { abs($0 - 0.2) < 0.001 })
        }
    }
}
