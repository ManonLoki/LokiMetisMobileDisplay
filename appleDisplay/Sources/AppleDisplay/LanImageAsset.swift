import Foundation
import CoreGraphics
import ImageIO

/// 已在网络后台解码的展示图片；帧只保存一次，逐帧时间不靠重复位图近似。
struct LanImageAsset {
    enum Failure: LocalizedError {
        case unsupportedFormat, invalidImage, resourceLimit
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "图片格式不受支持，请使用 BMP、PNG、JPEG、WebP 或 GIF。"
            case .invalidImage: return "图片内容损坏或格式与声明不一致。"
            case .resourceLimit: return "图片尺寸或动画帧数超出安全限制。"
            }
        }
    }

    /// 每张最多8MiB解码帧，最多十二个Hook约96MiB；编码正文仍限制32MiB。
    struct Limits {
        var maxEncodedBytes = Int(LanDisplaySnapshot.Asset.maxLength)
        var maxSourcePixels = 16_777_216
        var maxFrames = 512
        var maxDecodedBytes = 8 * 1024 * 1024
        var maxPixelSize = 512
    }
    /// 内容摘要即播放身份；同一图片重复解码不会让界面从头重播。
    let id: String
    let frames: [CGImage]
    let frameDurations: [TimeInterval]
    /// 0表示无限循环，其它值为总播放次数，统一GIF/PNG/WebP各自的循环语义。
    let playCount: Int
    let decodedByteCount: Int
    private let frameEnds: [TimeInterval]
    let duration: TimeInterval
    var isAnimated: Bool { frames.count > 1 }

    /// 运行于连接owner后台队列；完整动画成功后才发布，不悄悄以首帧替代损坏动画。
    static func decode(contentsOf url: URL, mime: String, id: String, limits: Limits = Limits()) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidImage }
        guard let size = values.fileSize, size > 0, size <= limits.maxEncodedBytes else { throw Failure.resourceLimit }
        return try decode(Data(contentsOf: url, options: .mappedIfSafe), mime: mime, id: id, limits: limits)
    }

    /// 按白名单 MIME 与尺寸限制解码，超限或格式不符即拒绝。
    static func decode(_ data: Data, mime: String, id: String, limits: Limits = Limits()) throws -> Self {
        guard LanDisplaySnapshot.Asset.supportedMimes.contains(mime) else { throw Failure.unsupportedFormat }
        guard !data.isEmpty, data.count <= limits.maxEncodedBytes,
              limits.maxFrames > 0, limits.maxPixelSize > 0, limits.maxDecodedBytes >= 4 else { throw Failure.resourceLimit }
        guard LanDisplaySnapshot.Asset.validMagic(data, mime: mime), let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetStatus(source) == .statusComplete else { throw Failure.invalidImage }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw Failure.invalidImage }
        guard count <= limits.maxFrames else { throw Failure.resourceLimit }
        let metadata = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        if let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber {
            guard width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= Double(limits.maxSourcePixels) else { throw Failure.resourceLimit }
        }
        var images: [CGImage] = [], delays: [TimeInterval] = [], ends: [TimeInterval] = []
        var bytes = 0, total: TimeInterval = 0
        // 以帧数分配统一边长，保持全部动画帧而不增加位图副本；实际行字节再严格核算。
        let perFrameBytes = limits.maxDecodedBytes / count
        let perFramePixels = perFrameBytes / 4
        let pixelSize = min(limits.maxPixelSize, Int(Double(perFramePixels).squareRoot()))
        guard pixelSize >= 1 else { throw Failure.resourceLimit }
        // 缩小后的边长沿用到后续帧，同尺寸画布不再逐帧重复超限解码。
        var edge = pixelSize
        for index in 0..<count {
            try autoreleasepool {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue > 0, height.doubleValue > 0,
                      width.doubleValue * height.doubleValue <= Double(limits.maxSourcePixels) else { throw Failure.resourceLimit }
                var frame = try thumbnail(source, index: index, pixelSize: edge)
                // ImageIO行字节含对齐开销；按实际占用缩小，不能把可缩放动画误判为超限。
                while frame.bytesPerRow * frame.height > perFrameBytes {
                    guard edge > 1 else { throw Failure.resourceLimit }
                    let ratio = Double(perFrameBytes) / Double(frame.bytesPerRow * frame.height)
                    edge = max(1, min(edge - 1, Int(Double(edge) * ratio.squareRoot())))
                    frame = try thumbnail(source, index: index, pixelSize: edge)
                }
                let size = frame.bytesPerRow * frame.height
                guard size <= limits.maxDecodedBytes - bytes else { throw Failure.resourceLimit }
                let delay = delayTime(properties, mime: mime)
                bytes += size; total += delay; images.append(frame); delays.append(delay); ends.append(total)
            }
        }
        return Self(id: id, frames: images, frameDurations: delays, playCount: plays(metadata, mime: mime),
                    decodedByteCount: bytes, frameEnds: ends, duration: total)
    }

    private static func thumbnail(_ source: CGImageSource, index: Int, pixelSize: Int) throws -> CGImage {
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { throw Failure.invalidImage }
        return frame
    }

    /// 直接按累计时长定位，快帧/慢帧保持原时序；有限播放结束后停留末帧。
    func frameIndex(at elapsed: TimeInterval) -> Int {
        guard frames.count > 1, elapsed.isFinite, elapsed > 0, duration > 0 else { return 0 }
        if playCount > 0, elapsed / duration >= Double(playCount) { return frames.count - 1 }
        let time = elapsed.truncatingRemainder(dividingBy: duration)
        return frameEnds.firstIndex(where: { time < $0 }) ?? frames.count - 1
    }

    /// 仅在下一帧到来时唤醒；有限循环完成后不再创建播放任务。
    func timeUntilNextFrame(at elapsed: TimeInterval) -> TimeInterval? {
        guard isAnimated, duration > 0 else { return nil }
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        if playCount > 0, elapsed / duration >= Double(playCount) { return nil }
        let time = elapsed.truncatingRemainder(dividingBy: duration)
        return (frameEnds.first(where: { time < $0 }) ?? duration) - time
    }

    private static func delayTime(_ properties: [CFString: Any], mime: String) -> TimeInterval {
        let dictionary: CFString, unclamped: CFString, clamped: CFString
        switch mime {
        case "image/gif": (dictionary, unclamped, clamped) = (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
        case "image/png": (dictionary, unclamped, clamped) = (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        case "image/webp": (dictionary, unclamped, clamped) = (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        default: return 0.1
        }
        let values = properties[dictionary] as? [CFString: Any] ?? [:]
        let value = (values[unclamped] as? NSNumber)?.doubleValue ?? (values[clamped] as? NSNumber)?.doubleValue ?? 0.1
        return value.isFinite && value > 0 ? value : 0.1
    }

    private static func plays(_ metadata: [CFString: Any], mime: String) -> Int {
        let dictionary: CFString, key: CFString
        switch mime {
        case "image/gif": (dictionary, key) = (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount)
        case "image/png": (dictionary, key) = (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount)
        case "image/webp": (dictionary, key) = (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount)
        default: return 1
        }
        let values = metadata[dictionary] as? [CFString: Any] ?? [:]
        guard let count = values[key] as? NSNumber else { return 1 }
        let value = count.intValue
        guard value > 0 else { return 0 }
        return mime == "image/gif" && value < Int.max ? value + 1 : value
    }
}

/// 内容摘要相同即同一张图（同一进程内解码参数固定），比较时不必逐帧比对位图。
extension LanImageAsset: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// 只累计实际播放时长；使用单调时钟，系统校时不会让动画停在某一帧。
struct LanImagePlaybackClock {
    private(set) var assetID: String?
    private var accumulated: TimeInterval = 0
    private var started: ContinuousClock.Instant?

    func elapsed(at instant: ContinuousClock.Instant) -> TimeInterval {
        guard let started else { return accumulated }
        let interval = started.duration(to: instant).components
        let seconds = Double(interval.seconds) + Double(interval.attoseconds) / 1e18
        return accumulated + max(0, seconds)
    }

    mutating func update(assetID: String, playing: Bool, at instant: ContinuousClock.Instant) {
        if self.assetID != assetID {
            self.assetID = assetID
            accumulated = 0
            started = nil
        }
        setPlaying(playing, at: instant)
    }

    mutating func setPlaying(_ playing: Bool, at instant: ContinuousClock.Instant) {
        if playing {
            if started == nil { started = instant }
        } else {
            accumulated = elapsed(at: instant)
            started = nil
        }
    }
}
