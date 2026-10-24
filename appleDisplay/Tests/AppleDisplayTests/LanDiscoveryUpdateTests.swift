import Foundation
import Network
import XCTest
@testable import AppleDisplay

final class LanDiscoveryUpdateTests: XCTestCase {
    private let phone = "12345678-1234-4234-8234-123456789abc"
    private let desktop = "22345678-1234-4234-8234-123456789abc"
    private let endpoint = NWEndpoint.service(name: "saved", type: "_loki-host._tcp", domain: "local.", interface: nil)

    /// 无效或冲突广告不能先撤销30秒恢复，再被候选校验丢弃而永久失去重试。
    func test_invalid_and_duplicate_advertisements_preserve_pending_recovery() {
        let queue = DispatchQueue(label: "test.loki.discovery.recovery")
        let scheduler = LanRetryScheduler(queue: queue)
        queue.sync {
            scheduler.schedule(after: 60) { XCTFail("test must cancel its recovery") }
            let valid = LanDiscoveryUpdate.Advertisement(id: desktop, version: "1", name: "Desktop", endpoint: endpoint)
            let invalidVersion = LanDiscoveryUpdate.Advertisement(id: desktop, version: "2", name: "Desktop", endpoint: endpoint)
            let invalidName = LanDiscoveryUpdate.Advertisement(id: desktop, version: "1", name: "", endpoint: endpoint)
            for advertisements in [[invalidVersion], [invalidName], [valid, valid]] {
                let found = LanDiscoveryUpdate.validated(advertisements, excluding: phone)
                XCTAssertNil(found[desktop])
                if LanDiscoveryUpdate.renewed(previous: endpoint, current: found[desktop]?.endpoint) { scheduler.cancel() }
                XCTAssertTrue(scheduler.isScheduled, "Rejected advertisements must preserve recovery")
            }
            scheduler.cancel()
        }
    }

    /// 同一服务改名不能绕过低频预算；新端点和合法服务重新出现仍可立即恢复。
    func test_metadata_changes_keep_backoff_but_a_new_endpoint_renews_it() {
        let changedName = LanDiscoveryUpdate.Advertisement(id: desktop, version: "1", name: "Renamed desktop", endpoint: endpoint)
        let found = LanDiscoveryUpdate.validated([changedName], excluding: phone)
        XCTAssertEqual(found[desktop]?.name, "Renamed desktop")
        XCTAssertFalse(LanDiscoveryUpdate.renewed(previous: endpoint, current: found[desktop]?.endpoint))
        XCTAssertTrue(LanDiscoveryUpdate.renewed(previous: nil, current: found[desktop]?.endpoint))
        let replacement = NWEndpoint.service(name: "new-service", type: "_loki-host._tcp", domain: "local.", interface: nil)
        XCTAssertTrue(LanDiscoveryUpdate.renewed(previous: endpoint, current: replacement))
    }
}
