import Foundation
import XCTest
@testable import AppleDisplay

/// 使用真实串行队列验证快速前后台/网络变化撤销重试后，旧工作不能覆盖新连接意图。
final class LanRetrySchedulerTests: XCTestCase {
    func test_cancelled_retry_does_not_run_after_foreground_owner_stops() {
        let queue = DispatchQueue(label: "test.loki.retry.cancel")
        let scheduler = LanRetryScheduler(queue: queue)
        let drained = expectation(description: "cancelled work drained")
        queue.async {
            scheduler.schedule(after: 0) { XCTFail("cancelled retry must not reopen a connection") }
            XCTAssertTrue(scheduler.isScheduled)
            scheduler.cancel()
            XCTAssertFalse(scheduler.isScheduled)
            queue.async { drained.fulfill() }
        }
        wait(for: [drained], timeout: 2)
    }

    func test_new_retry_replaces_old_queued_work_and_runs_once() {
        let queue = DispatchQueue(label: "test.loki.retry.replace")
        let scheduler = LanRetryScheduler(queue: queue)
        let completed = expectation(description: "new recovery ran")
        var calls = 0
        queue.async {
            scheduler.schedule(after: 0) { XCTFail("stale retry must not replace a healthy session") }
            scheduler.schedule(after: 0) {
                calls += 1
                XCTAssertFalse(scheduler.isScheduled)
                completed.fulfill()
            }
            XCTAssertTrue(scheduler.isScheduled)
        }
        wait(for: [completed], timeout: 2)
        queue.sync { XCTAssertEqual(calls, 1) }
    }

    func test_missing_endpoint_can_schedule_next_recovery_from_current_callback() {
        let queue = DispatchQueue(label: "test.loki.retry.continue")
        let scheduler = LanRetryScheduler(queue: queue)
        let completed = expectation(description: "recovery continued")
        queue.async {
            scheduler.schedule(after: 0) {
                scheduler.schedule(after: 0) { completed.fulfill() }
                XCTAssertTrue(scheduler.isScheduled)
            }
        }
        wait(for: [completed], timeout: 2)
        queue.sync { XCTAssertFalse(scheduler.isScheduled) }
    }
}
