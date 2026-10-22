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

    /// 图片使用 32 MiB 协议边界；超过快照容量仍能完整提交，非法块不能推进真实文件偏移。
    func test_shared_asset_chunks_reject_unsigned_offsets_and_preserve_large_transfer_progress() throws {
        let cache = try WatchAssetCache(directory: temporaryFolder())
        let header = try TestImages.encoded("com.compuserve.gif", mime: "image/gif")
        let data = header + Data(repeating: 0, count: WatchProtocol.maxSnapshotBytes + 7)
        let asset = LanDisplaySnapshot.Asset(hash: WatchProtocol.hash(data), mime: "image/gif", length: UInt64(data.count))
        try cache.begin(asset, id: transfer)
        let first = data.prefix(WatchProtocol.chunkSize)
        for offset in [UInt64(1), UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertThrowsError(try cache.accept(id: transfer, offset: offset, data: first))
        }
        XCTAssertThrowsError(try cache.accept(id: UUID().uuidString.lowercased(), offset: 0, data: first))
        XCTAssertThrowsError(try cache.accept(id: transfer, offset: 0, data: Data()))
        XCTAssertThrowsError(try cache.accept(id: transfer, offset: 0, data: first.dropLast()))
        XCTAssertThrowsError(try cache.accept(id: transfer, offset: 0, data: data.prefix(WatchProtocol.chunkSize + 1)))
        let accepted = try cache.accept(id: transfer, offset: 0, data: first)
        XCTAssertEqual(accepted.0, UInt64(WatchProtocol.chunkSize))
        XCTAssertNil(accepted.1)
        XCTAssertThrowsError(try cache.accept(id: transfer, offset: 0, data: first))
        XCTAssertThrowsError(try cache.accept(id: transfer, offset: UInt64(WatchProtocol.chunkSize * 2), data: first))
        var offset = WatchProtocol.chunkSize
        var committed: URL?
        while offset < data.count {
            let end = min(offset + WatchProtocol.chunkSize, data.count)
            let result = try cache.accept(id: transfer, offset: UInt64(offset), data: data.subdata(in: offset..<end))
            XCTAssertEqual(result.0, UInt64(end))
            if end < data.count { XCTAssertNil(result.1) }
            committed = result.1
            offset = end
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(committed)), data)
        XCTAssertNotNil(try cache.cached(asset))
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

    /// 原生枚举和删除消费共享淘汰计划：保护最旧引用，按复用时间删除下一份旧文件。
    func test_shared_eviction_keeps_referenced_files_and_removes_only_the_oldest_candidate() throws {
        let directory = try temporaryFolder()
        let cache = try WatchAssetCache(directory: directory)
        var files: [URL] = []
        for index in 0..<513 {
            let path = directory.appendingPathComponent(String(format: "%064x", index))
            try Data().write(to: path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: path.path)
            files.append(path)
        }
        cache.prune(keeping: [files[0].lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[2].path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 512)
    }

    /// 删除失败不能把当前引用集标为已收敛；恢复目录写权限后同一 keeping 必须重新扫描。
    func test_failed_eviction_retries_the_same_references_after_directory_permissions_recover() throws {
        let manager = FileManager.default
        let directory = try temporaryFolder()
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        let cache = try WatchAssetCache(directory: directory)
        var files: [URL] = []
        for index in 0..<513 {
            let path = directory.appendingPathComponent(String(format: "%064x", index))
            try Data().write(to: path)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: path.path)
            files.append(path)
        }
        let keeping: Set<String> = [files[0].lastPathComponent]
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        // 特权运行环境可能绕过 POSIX 权限；先验证用例确实能产生真实删除失败。
        var couldUnlink = false
        do { try manager.removeItem(at: files[1]); couldUnlink = true } catch { }
        guard !couldUnlink else { throw XCTSkip("当前进程可绕过目录写权限，无法制造删除失败。") }

        cache.prune(keeping: keeping)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path).count, 513)
        XCTAssertTrue(manager.fileExists(atPath: files[0].path))
        XCTAssertTrue(manager.fileExists(atPath: files[1].path))

        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        cache.prune(keeping: keeping)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path).count, 512)
        XCTAssertTrue(manager.fileExists(atPath: files[0].path))
        XCTAssertFalse(manager.fileExists(atPath: files[1].path))
        XCTAssertTrue(manager.fileExists(atPath: files[2].path))
    }
}
