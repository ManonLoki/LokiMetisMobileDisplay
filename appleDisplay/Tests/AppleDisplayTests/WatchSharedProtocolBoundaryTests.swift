import Foundation
import XCTest
@testable import AppleDisplay

/// 原生外壳实际调用共享策略，完整 UInt64 纳秒与 struct 副本都不能在桥接时失真。
final class WatchSharedProtocolBoundaryTests: XCTestCase {
    private let session = "12345678-1234-4234-8234-123456789abc"

    func test_full_unsigned_clock_range_and_copy_semantics_survive_shared_bridge() throws {
        let base = UInt64.max - 45_000_000_000
        var lease = WatchForegroundLease()
        try lease.activate(session: session)
        try lease.received(session: session, now: base)
        let saved = lease
        XCTAssertEqual(saved.lastContact, base)
        XCTAssertTrue(saved.reachable(now: UInt64.max - 1))
        XCTAssertFalse(saved.reachable(now: UInt64.max))
        XCTAssertFalse(saved.reachable(now: 0))
        try lease.received(session: session, now: UInt64.max)
        XCTAssertEqual(lease.lastContact, UInt64.max)
        XCTAssertEqual(saved.lastContact, base)
        lease.deactivate()
        XCTAssertEqual(saved.session, session)
        XCTAssertNil(lease.session)
    }

    func test_ack_fact_snapshot_copy_and_rounding_above_signed_long_range() throws {
        let base = UInt64(Int64.max) + 1
        let info = WatchDeviceInfo(deviceId: session, name: "Watch", appVersion: "1.0")
        var facts = WatchCompanionFacts()
        try facts.received(now: base, synchronized: true)
        let saved = facts
        try facts.received(now: base + 1)
        let snapshot = try saved.report(info: info, reachable: true, now: base + 1)
        XCTAssertEqual(snapshot["contact"] as? [String: UInt64], ["sequence": 1, "ageMs": 1])
        XCTAssertEqual(snapshot["sync"] as? [String: UInt64], ["sequence": 1, "ageMs": 1])
        XCTAssertEqual((try facts.report(info: info, reachable: true, now: base + 1)["contact"] as? [String: UInt64])?["sequence"], 2)
        XCTAssertEqual(try saved.report(info: info, reachable: true, now: base + 44_999_000_000)["reachable"] as? Bool, true)
        XCTAssertEqual(try saved.report(info: info, reachable: true, now: base + 44_999_000_001)["reachable"] as? Bool, false)
        XCTAssertThrowsError(try facts.received(now: 0))
        XCTAssertNil(try saved.report(info: info, reachable: true, now: UInt64.max)["contact"])
    }

    func test_unsigned_snapshot_lengths_offsets_and_rpc_versions_fail_without_integer_traps() throws {
        let receiver = WatchSnapshotAssembler()
        XCTAssertThrowsError(try receiver.begin(id: session, hash: String(repeating: "a", count: 64), length: UInt64.max))
        try receiver.begin(id: session, hash: String(repeating: "a", count: 64), length: 1)
        XCTAssertThrowsError(try receiver.accept(id: session, offset: UInt64.max, data: Data([0])))
        let version = Data("{\"version\":\(Int.max),\"op\":\"probe\"}".utf8)
        XCTAssertThrowsError(try WatchProtocol.request(version))
    }
}
