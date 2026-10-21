import Foundation
import XCTest
@testable import AppleDisplay

/// 分帧使用真实编码字节测试分段与坏头部，不依赖网络或私有身份。
final class LanFramesTests: XCTestCase {
    /// 任意半头部和半载荷都只能在完整接收后交付一次。
    func test_fragmented_header_and_payload_are_retained() throws {
        let frame = try LanFrames.encode(Data("你好".utf8), limit: 4096)
        var decoder = LanFrames()
        for byte in frame.dropLast() {
            try decoder.append(Data([byte]))
            XCTAssertNil(try decoder.next(limit: 4096))
        }
        try decoder.append(Data(frame.suffix(1)))
        XCTAssertEqual(try decoder.next(limit: 4096), Data("你好".utf8))
        XCTAssertNil(try decoder.next(limit: 4096))
    }

    /// 合并到一次接收的多帧仍严格分开；第二帧使用阶段切换后的容量边界。
    func test_coalesced_frames_apply_each_phase_limit() throws {
        let first = try LanFrames.encode(Data("ack".utf8), limit: 4096)
        let second = try LanFrames.encode(Data(repeating: 1, count: 5000), limit: 98304)
        var decoder = LanFrames()
        try decoder.append(first + second)
        XCTAssertEqual(try decoder.next(limit: 4096), Data("ack".utf8))
        XCTAssertThrowsError(try decoder.next(limit: 4096))
        XCTAssertEqual(try decoder.next(limit: 98304)?.count, 5000)
    }

    /// 零长度与过大长度只收到四字节就失败，无需先分配或读取载荷。
    func test_invalid_lengths_fail_before_payload_allocation() throws {
        for header in [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 16, 1])] {
            var decoder = LanFrames()
            try decoder.append(header)
            XCTAssertThrowsError(try decoder.next(limit: 4096))
        }
    }
}
