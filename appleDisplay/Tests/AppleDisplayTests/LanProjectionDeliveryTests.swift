import XCTest
@testable import AppleDisplay

/// 主线程任务真正运行后检查接收值，验证队列合并与消费中更新不会丢失。
final class LanProjectionDeliveryTests: XCTestCase {
    /// 一千次突发提交只交付最后一份，避免UI积压一千份旧图片与快照。
    @MainActor func test_burst_keeps_only_latest_pending_projection() {
        let delivered = expectation(description: "latest projection delivered")
        var values: [Int] = []
        let mailbox = LanProjectionDelivery<Int> { value in values.append(value); delivered.fulfill() }
        for value in 0..<1000 { mailbox.submit(value) }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(values, [999])
    }

    /// 消费当前值时到来的更新被合并成下一份，并在同一主队列顺序交付。
    @MainActor func test_updates_during_consumption_deliver_one_following_value() {
        let delivered = expectation(description: "following projection delivered")
        var values: [Int] = []
        var mailbox: LanProjectionDelivery<Int>!
        mailbox = LanProjectionDelivery<Int> { value in
            values.append(value)
            if value == -1 { for next in 0..<100 { mailbox.submit(next) } }
            else { delivered.fulfill() }
        }
        mailbox.submit(-1)
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(values, [-1, 99])
        mailbox = nil
    }
}
