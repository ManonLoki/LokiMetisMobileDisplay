import CoreGraphics
import Foundation
import ImageIO
import XCTest

extension XCTestCase {
    /// 测试自建临时私有目录并在用例结束时回收，不读取真实HOME或共享容器。
    func temporaryFolder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
}

/// ImageIO编码的测试图片；帧红蓝交替，首帧0.05秒、其余0.2秒，`loops`为nil时不写循环属性。
enum TestImages {
    static func encoded(_ type: String, mime: String, frames: Int = 1, size: Int = 8, loops: Int? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
        let dictionary = mime == "image/gif" ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loopKey = mime == "image/gif" ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        let delayKey = mime == "image/gif" ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
        if let loops { CGImageDestinationSetProperties(destination, [dictionary: [loopKey: loops]] as CFDictionary) }
        for index in 0..<frames {
            let red: CGFloat = index.isMultiple(of: 2) ? 1 : 0
            let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [dictionary: [delayKey: index == 0 ? 0.05 : 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
