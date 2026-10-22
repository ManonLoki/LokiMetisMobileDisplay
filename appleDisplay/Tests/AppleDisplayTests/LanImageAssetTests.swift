import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AppleDisplay

final class LanImageAssetTests: XCTestCase {
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
        let still = try LanImageAsset.decode(webp(animated: false), mime: "image/webp", id: "fixture")
        XCTAssertEqual(still.frames.count, 1)
        let animated = try LanImageAsset.decode(webp(animated: true), mime: "image/webp", id: "fixture")
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
            let value = try LanImageAsset.decode(TestImages.encoded(type, mime: mime), mime: mime, id: "fixture")
            XCTAssertEqual(value.frames.count, 1)
            XCTAssertFalse(value.isAnimated)
            XCTAssertEqual(value.frames[0].width, 8)
            XCTAssertLessThanOrEqual(value.decodedByteCount, 8 * 1024 * 1024)
        }
    }

    func test_gif_and_animated_png_keep_all_frames_and_original_delays() throws {
        for (type, mime) in [("com.compuserve.gif", "image/gif"), ("public.png", "image/png")] {
            let value = try LanImageAsset.decode(TestImages.encoded(type, mime: mime, frames: 2, loops: 0), mime: mime, id: "fixture")
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
        let value = try LanImageAsset.decode(TestImages.encoded("public.png", mime: "image/png", frames: 2, loops: 2), mime: "image/png", id: "fixture")
        XCTAssertEqual(value.playCount, 2)
        XCTAssertEqual(value.frameIndex(at: 0.26), 0)
        XCTAssertEqual(value.frameIndex(at: 0.6), 1)
    }

    func test_frame_wakeups_follow_original_delays_and_stop_after_finite_loops() throws {
        let data = try TestImages.encoded("public.png", mime: "image/png", frames: 2, loops: 2)
        let asset = try LanImageAsset.decode(data, mime: "image/png", id: "finite")
        XCTAssertEqual(try XCTUnwrap(asset.timeUntilNextFrame(at: 0)), 0.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(asset.timeUntilNextFrame(at: 0.08)), 0.17, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(asset.timeUntilNextFrame(at: asset.duration)), 0.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(asset.timeUntilNextFrame(at: 0.49)), 0.01, accuracy: 0.001)
        XCTAssertNil(asset.timeUntilNextFrame(at: asset.duration * 2))
        XCTAssertNil(asset.timeUntilNextFrame(at: 3600))
        let still = try LanImageAsset.decode(TestImages.encoded("public.png", mime: "image/png"), mime: "image/png", id: "still")
        XCTAssertNil(still.timeUntilNextFrame(at: 0))
    }

    func test_pause_and_resume_keep_frame_and_do_not_consume_finite_loops() throws {
        let asset = try LanImageAsset.decode(TestImages.encoded("public.png", mime: "image/png", frames: 2, loops: 2), mime: "image/png", id: "finite")
        let start = ContinuousClock.now
        var clock = LanImagePlaybackClock()
        clock.update(assetID: asset.id, playing: true, at: start)
        clock.setPlaying(false, at: start.advanced(by: .seconds(0.08)))
        let resume = start.advanced(by: .seconds(3600))
        XCTAssertEqual(clock.elapsed(at: resume), 0.08, accuracy: 0.001)
        XCTAssertEqual(asset.frameIndex(at: clock.elapsed(at: resume)), 1)
        XCTAssertNotNil(asset.timeUntilNextFrame(at: clock.elapsed(at: resume)))
        clock.update(assetID: asset.id, playing: true, at: resume)
        XCTAssertEqual(clock.elapsed(at: resume.advanced(by: .seconds(0.2))), 0.28, accuracy: 0.001)
        XCTAssertEqual(asset.frameIndex(at: clock.elapsed(at: resume.advanced(by: .seconds(0.2)))), 0)
        XCTAssertNil(asset.timeUntilNextFrame(at: clock.elapsed(at: resume.advanced(by: .seconds(0.43)))))
    }

    func test_same_content_refresh_does_not_restart_playback_but_new_asset_does() throws {
        let start = ContinuousClock.now
        var clock = LanImagePlaybackClock()
        clock.update(assetID: "first", playing: true, at: start)
        clock.update(assetID: "first", playing: true, at: start.advanced(by: .seconds(10)))
        XCTAssertEqual(clock.elapsed(at: start.advanced(by: .seconds(11))), 11, accuracy: 0.001)
        clock.update(assetID: "second", playing: true, at: start.advanced(by: .seconds(12)))
        XCTAssertEqual(clock.assetID, "second")
        XCTAssertEqual(clock.elapsed(at: start.advanced(by: .seconds(12))), 0, accuracy: 0.001)
        clock.update(assetID: "third", playing: false, at: start.advanced(by: .seconds(13)))
        XCTAssertEqual(clock.elapsed(at: start.advanced(by: .seconds(100))), 0, accuracy: 0.001)
    }

    func test_infinite_animation_continues_after_long_run_and_many_lifecycle_pauses() throws {
        let asset = try LanImageAsset.decode(TestImages.encoded("public.png", mime: "image/png", frames: 2, loops: 0), mime: "image/png", id: "infinite")
        let start = ContinuousClock.now
        var clock = LanImagePlaybackClock()
        for index in 0..<1000 {
            let active = start.advanced(by: .seconds(index * 60))
            clock.update(assetID: asset.id, playing: true, at: active)
            clock.setPlaying(false, at: active.advanced(by: .seconds(0.1)))
        }
        let resume = start.advanced(by: .seconds(60_000))
        XCTAssertEqual(clock.elapsed(at: resume), 100, accuracy: 0.001)
        clock.update(assetID: asset.id, playing: true, at: resume)
        let later = clock.elapsed(at: resume.advanced(by: .seconds(86400.08)))
        XCTAssertEqual(asset.frameIndex(at: later), 1)
        let remaining = try XCTUnwrap(asset.timeUntilNextFrame(at: later))
        XCTAssertGreaterThan(remaining, 0.16)
        XCTAssertLessThan(remaining, 0.18)
    }

    func test_frame_count_pixels_bytes_and_format_are_bounded() throws {
        let data = try TestImages.encoded("com.compuserve.gif", mime: "image/gif", frames: 2, loops: 0)
        var limits = LanImageAsset.Limits(); limits.maxFrames = 1
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/gif", id: "fixture", limits: limits))
        limits = .init(); limits.maxSourcePixels = 1
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/gif", id: "fixture", limits: limits))
        limits = .init(); limits.maxEncodedBytes = data.count - 1
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/gif", id: "fixture", limits: limits))
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/png", id: "fixture"))
        XCTAssertThrowsError(try LanImageAsset.decode(Data("not an image".utf8), mime: "image/gif", id: "fixture"))
        XCTAssertThrowsError(try LanImageAsset.decode(data, mime: "image/tiff", id: "fixture"))
    }

    func test_cached_file_decodes_but_symlink_and_truncated_animation_are_rejected() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("verified-image"), link = folder.appendingPathComponent("symlink")
        let data = try TestImages.encoded("com.compuserve.gif", mime: "image/gif", frames: 2, loops: 0)
        try data.write(to: file)
        XCTAssertEqual(try LanImageAsset.decode(contentsOf: file, mime: "image/gif", id: "fixture").frames.count, 2)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try LanImageAsset.decode(contentsOf: link, mime: "image/gif", id: "fixture"))
        XCTAssertThrowsError(try LanImageAsset.decode(Data(data.prefix(data.count / 2)), mime: "image/gif", id: "fixture"))
    }

    func test_decoded_budget_downsamples_without_dropping_animation_frames() throws {
        let data = try TestImages.encoded("com.compuserve.gif", mime: "image/gif", frames: 2, loops: 0)
        var limits = LanImageAsset.Limits(); limits.maxDecodedBytes = 128
        let value = try LanImageAsset.decode(data, mime: "image/gif", id: "fixture", limits: limits)
        XCTAssertEqual(value.frames.count, 2)
        XCTAssertLessThanOrEqual(value.decodedByteCount, limits.maxDecodedBytes)
        XCTAssertLessThan(value.frames[0].width, 8)
    }
}
