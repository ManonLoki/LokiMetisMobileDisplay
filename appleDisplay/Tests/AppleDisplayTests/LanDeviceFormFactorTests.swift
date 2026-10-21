import XCTest
@testable import AppleDisplay

/// 真实认证能力与每连接状态确保形态扩展兼容旧端，未知系统类别保持中性。
final class LanDeviceFormFactorTests: XCTestCase {
    /// phone/pad上报同一协议字段；无能力不发，单连接只发一次，重连重新协商。
    func test_type_report_requires_live_capability_and_resets_on_reconnection() throws {
        for type in [LanDeviceFormFactor.phone, .tablet] {
            var report = LanDeviceFormFactorReport(formFactor: type)
            XCTAssertNil(try report.afterAuthenticatedSnapshot([:]))
            XCTAssertNil(try report.afterAuthenticatedSnapshot(["capabilities": ["watchCompanionV1"]]))
            let supported: [String: Any] = ["capabilities": ["deviceFormFactorV1", "watchCompanionV1"]]
            let message = try XCTUnwrap(report.afterAuthenticatedSnapshot(supported))
            XCTAssertEqual(message["type"] as? String, "deviceFormFactor")
            XCTAssertEqual(message["formFactor"] as? String, type.rawValue)
            XCTAssertNil(try report.afterAuthenticatedSnapshot(supported))
            report.reset()
            XCTAssertNil(try report.afterAuthenticatedSnapshot([:]))
            XCTAssertNotNil(try report.afterAuthenticatedSnapshot(supported))
        }
        var unknown = LanDeviceFormFactorReport(formFactor: nil)
        XCTAssertNil(try unknown.afterAuthenticatedSnapshot(["capabilities": ["deviceFormFactorV1"]]))
    }
    /// 严格有界能力表复用Watch校验，坏输入不能提前消耗上报状态。
    func test_invalid_capability_list_does_not_enable_or_consume_report() throws {
        var report = LanDeviceFormFactorReport(formFactor: .tablet)
        for invalid: Any in [true, [true], [""], ["deviceFormFactorV1", "deviceFormFactorV1"], (0..<17).map { "cap\($0)" }, [String(repeating: "长", count: 22)]] {
            XCTAssertThrowsError(try report.afterAuthenticatedSnapshot(["capabilities": invalid]))
        }
        XCTAssertNotNil(try report.afterAuthenticatedSnapshot(["capabilities": ["deviceFormFactorV1"]]))
    }
}
