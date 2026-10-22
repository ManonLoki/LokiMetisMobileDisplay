import Foundation
import XCTest
@testable import AppleDisplay

/// 真实线字段的隔离夹具验证组件投影、质量和缓存保留，不连接局域网或访问真实App Group。
final class WidgetSnapshotTests: XCTestCase {
    private let source = "12345678-1234-4234-8234-123456789abc"
    private let fixture = #"{"type":"snapshot","snapshot":{"version":1,"tokens":{"day":{"date":"2026-10-21","zone":"Asia/Shanghai","startMs":1000,"endMs":86401000},"observedMs":2000,"all":{"total":"18446744073709551615","availability":"available","completeness":"partial","confidence":"derived"},"agents":[{"agent":"codex","amount":{"total":"0","availability":"available","completeness":"complete","confidence":"exact"}}]},"tokenError":null,"hooksAvailable":true,"hooks":[{"agent":"codex","slot":1,"behavior":"running","content":"private-hook-text","contentTruncated":false,"image":"private-image-hash"}],"assets":[{"secret":"must-not-survive"}]}}"#

    /// 固定接收时间与来源构造真实投影，避免测试依赖当前时钟。
    private func record(_ json: String? = nil) throws -> WidgetSnapshot {
        try WidgetSnapshot.authenticatedMessage(Data((json ?? fixture).utf8), sourceId: source, receivedAtMs: 3000)
    }

    /// 每个文件测试使用独立目录，并只清理自身创建的目录。
    private func isolated(_ body: (WidgetSnapshotStore) throws -> Void) throws {
        let directory = try temporaryFolder()
        try body(WidgetSnapshotStore(directory: directory))
    }

    /// 完整u64与质量标记贯穿解码和显示，精确零与缺记录分别保留。
    func test_preserves_u64_quality_and_exact_zero() throws {
        let value = try record()
        XCTAssertEqual(value.snapshot.tokens?.all.text, "18446744073709551615")
        XCTAssertEqual(value.snapshot.tokens?.all.quality, "部分·估算")
        XCTAssertEqual(value.snapshot.tokens?.agents.first?.amount.text, "0")
        XCTAssertEqual(value.snapshot.tokens?.day.date, "2026-10-21")
        let missing = try record(fixture.replacingOccurrences(of: "\"total\":\"0\",\"availability\":\"available\"", with: "\"total\":null,\"availability\":\"noRecords\""))
        XCTAssertEqual(missing.snapshot.tokens?.agents.first?.amount.text, "无记录")
    }

    /// Codable白名单编码确保Hook正文、图片、原始assets与额外密钥不会进入共享文件。
    func test_encoding_drops_private_and_unneeded_fields() throws {
        let value = try record(fixture.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"secret\":\"private-key\""))
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for value in ["private-hook-text", "private-image-hash", "must-not-survive", "private-key", "assets", "content"] {
            XCTAssertFalse(encoded.contains(value))
        }
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: Data(encoded.utf8)), value)
    }

    /// 非规范整数、未知版本、重复槽位和不一致日界不能覆盖有效缓存。
    func test_rejects_invalid_wire_values() throws {
        for invalid in [fixture.replacingOccurrences(of: "18446744073709551615", with: "18446744073709551616"),
                        fixture.replacingOccurrences(of: "18446744073709551615", with: "01"),
                        fixture.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                        fixture.replacingOccurrences(of: "\"observedMs\":2000", with: "\"observedMs\":999"),
                        fixture.replacingOccurrences(of: "\"hooksAvailable\":true", with: "\"hooksAvailable\":false"),
                        fixture.replacingOccurrences(of: "\"slot\":1", with: "\"slot\":0")] {
            XCTAssertThrowsError(try record(invalid))
        }
        XCTAssertThrowsError(try WidgetSnapshot.authenticatedMessage(Data(fixture.utf8), sourceId: "bad-id", receivedAtMs: 1))
        XCTAssertThrowsError(try record(fixture.replacingOccurrences(of: "\"type\":\"snapshot\"", with: "\"type\":\"assetChunk\"")))
    }

    /// 新完整快照清空Hook/Token时必须实际替换旧状态，不能保留旧运行槽位或数字。
    func test_complete_snapshot_replaces_released_state() throws {
        try isolated { store in
            let before = try record()
            try store.saveAuthenticatedSnapshot(before, refreshTarget: nil)
            XCTAssertEqual(try store.load(), before)
            let released = try record(#"{"type":"snapshot","snapshot":{"version":1,"tokens":null,"tokenError":"unavailable","hooksAvailable":true,"hooks":[]}}"#)
            try store.saveAuthenticatedSnapshot(released, refreshTarget: nil)
            let loaded = try store.load()
            XCTAssertNil(loaded.snapshot.tokens)
            XCTAssertTrue(loaded.snapshot.hooks.isEmpty)
            XCTAssertEqual(loaded.snapshot.hooksText, "Hooks 0")
        }
    }

    /// 无效更新先验证后写入，失败后原有效文件逐字节保留。
    func test_invalid_update_preserves_previous_bytes() throws {
        try isolated { store in
            let before = try record()
            try store.saveAuthenticatedSnapshot(before, refreshTarget: nil)
            let file = store.directory.appendingPathComponent("display-widget-v1.json")
            let bytes = try Data(contentsOf: file)
            let invalid = WidgetSnapshot(schemaVersion: 2, sourceId: source, receivedAtMs: 4000, snapshot: before.snapshot)
            XCTAssertThrowsError(try store.saveAuthenticatedSnapshot(invalid, refreshTarget: nil))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try store.load(), before)
        }
    }

    /// 错误路径不覆盖目录或其文件，真实写入失败保留已有对象。
    func test_write_failure_preserves_conflicting_directory() throws {
        try isolated { store in
            let path = store.directory.appendingPathComponent("display-widget-v1.json", isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            let sentinel = path.appendingPathComponent("keep")
            try Data("original".utf8).write(to: sentinel)
            XCTAssertThrowsError(try store.saveAuthenticatedSnapshot(record(), refreshTarget: nil))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
        }
    }

    /// 未同步、损坏、超大文件分别失败，不产生虚构零值。
    func test_missing_corrupt_and_oversized_cache_fail_closed() throws {
        try isolated { store in
            XCTAssertThrowsError(try store.load())
            let path = store.directory.appendingPathComponent("display-widget-v1.json")
            try Data("broken".utf8).write(to: path)
            XCTAssertThrowsError(try store.load())
            try Data(repeating: 32, count: WidgetSnapshot.maxBytes + 1).write(to: path)
            XCTAssertThrowsError(try store.load())
        }
    }

    /// 共享文件符号链接不能把组件读写导向容器内其他资料。
    func test_symlink_is_not_followed_or_overwritten() throws {
        try isolated { store in
            let sentinel = store.directory.appendingPathComponent("original")
            try Data("untouched".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("display-widget-v1.json"), withDestinationURL: sentinel)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.saveAuthenticatedSnapshot(record(), refreshTarget: nil))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        }
    }
    /// 当前连接45秒租约失效或墙钟回拨时不恢复摘要，心跳仅能续尚未过期的记录。
    func test_live_summary_expires_and_does_not_revive_after_disconnect() throws {
        let value = try record()
        XCTAssertTrue(value.isLive(atMs: 3000))
        XCTAssertTrue(value.isLive(atMs: 47_999))
        XCTAssertFalse(value.isLive(atMs: 48_000))
        XCTAssertFalse(value.isLive(atMs: 2999))
        XCTAssertNil(value.renewed(atMs: 48_000))
        let renewed = try XCTUnwrap(value.renewed(atMs: 18_000))
        XCTAssertTrue(renewed.isLive(atMs: 48_000))
        try isolated { store in
            try store.saveAuthenticatedSnapshot(value, refreshTarget: nil)
            XCTAssertNotNil(try store.loadLive(atMs: 3000))
            XCTAssertNil(try store.loadLive(atMs: 48_000))
            try store.clear(); try store.clear()
            XCTAssertThrowsError(try store.load())
        }
    }

    /// 连接租约结束只撤销续期资格；小组件保留最后一次摘要而不虚构实时状态。
    func test_cached_summary_survives_live_lease_and_crossing_days() throws {
        let value = try record()
        let nextDay = value.receivedAtMs + 2 * 86_400_000
        XCTAssertTrue(value.isCached(atMs: 48_000))
        XCTAssertFalse(value.isLive(atMs: 48_000))
        XCTAssertTrue(value.isCached(atMs: nextDay))
        XCTAssertNil(value.renewed(atMs: nextDay))
        try isolated { store in
            try store.saveAuthenticatedSnapshot(value, refreshTarget: nil)
            XCTAssertEqual(try store.loadCached(atMs: 48_000), value)
            let cached = try XCTUnwrap(store.loadCached(atMs: nextDay))
            XCTAssertEqual(cached.receivedAtMs, 3000)
            XCTAssertEqual(cached.snapshot.tokens?.day.date, "2026-10-21")
            XCTAssertEqual(cached.snapshot.tokens?.day.zone, "Asia/Shanghai")
            XCTAssertEqual(cached.snapshot.tokens?.all.text, "18446744073709551615")
            XCTAssertNil(try store.loadLive(atMs: nextDay))
        }
    }

    /// 回拨或远超当前时钟的未来租约都不能被缓存入口当作可信摘要。
    func test_cached_summary_rejects_future_receipt_and_unreasonable_future_lease() throws {
        let value = try record()
        XCTAssertFalse(value.isCached(atMs: 2999))
        try isolated { store in
            try store.saveAuthenticatedSnapshot(value, refreshTarget: nil)
            XCTAssertNil(try store.loadCached(atMs: 2999))
            let futureLease = WidgetSnapshot(schemaVersion: 2, sourceId: source, receivedAtMs: 3000,
                                             snapshot: value.snapshot, validUntilMs: 100_000)
            try store.saveAuthenticatedSnapshot(futureLease, refreshTarget: nil)
            XCTAssertFalse(futureLease.isCached(atMs: 3000))
            XCTAssertNil(try store.loadCached(atMs: 3000))
        }
    }

    /// 多次真实心跳可把租约续到远离首次接收时间，合法长连接仍可共享摘要。
    func test_repeated_heartbeat_renewal_preserves_cached_summary() throws {
        var value = try record()
        for now in stride(from: Int64(33_000), through: 183_000, by: 30_000) {
            value = try XCTUnwrap(value.renewed(atMs: now))
            XCTAssertNoThrow(try value.validate())
            XCTAssertTrue(value.isLive(atMs: now))
            XCTAssertTrue(value.isCached(atMs: now))
        }
        XCTAssertEqual(value.receivedAtMs, 3000)
        XCTAssertEqual(value.validUntilMs, 228_000)
        try isolated { store in
            try store.saveAuthenticatedSnapshot(value, refreshTarget: nil)
            XCTAssertEqual(try store.loadCached(atMs: 183_000), value)
            XCTAssertEqual(try store.loadCached(atMs: 228_000), value)
            XCTAssertNil(try store.loadLive(atMs: 228_000))
        }
    }

    /// schema2仍要求完整初始租约；短租约、缺失和加法溢出不能进入持久化。
    func test_rejects_malformed_lease_bounds() throws {
        let before = try record()
        let malformed = [
            WidgetSnapshot(schemaVersion: 2, sourceId: source, receivedAtMs: 3000, snapshot: before.snapshot),
            WidgetSnapshot(schemaVersion: 2, sourceId: source, receivedAtMs: 3000, snapshot: before.snapshot, validUntilMs: 2999),
            WidgetSnapshot(schemaVersion: 2, sourceId: source, receivedAtMs: 3000, snapshot: before.snapshot, validUntilMs: 47_999),
            WidgetSnapshot(schemaVersion: 2, sourceId: source, receivedAtMs: Int64.max - 1, snapshot: before.snapshot, validUntilMs: Int64.max)
        ]
        try isolated { store in
            try store.saveAuthenticatedSnapshot(before, refreshTarget: nil)
            for invalid in malformed {
                XCTAssertThrowsError(try invalid.validate())
                XCTAssertFalse(invalid.isCached(atMs: invalid.receivedAtMs))
                XCTAssertFalse(invalid.isLive(atMs: invalid.receivedAtMs))
                XCTAssertThrowsError(try store.saveAuthenticatedSnapshot(invalid, refreshTarget: nil))
                XCTAssertEqual(try store.loadCached(atMs: 48_000), before)
            }
        }
    }

    /// 忘记或切换桌面的明确清除使已过期缓存也不可再读，重复清除保持幂等。
    func test_explicit_clear_removes_cached_summary() throws {
        try isolated { store in
            let value = try record()
            try store.saveAuthenticatedSnapshot(value, refreshTarget: nil)
            XCTAssertEqual(try store.loadCached(atMs: 100_000), value)
            try store.clear(); try store.clear()
            XCTAssertThrowsError(try store.loadCached(atMs: 100_000))
        }
    }

    /// 历史文件缺少连接租约，即使数字合法也不能显示。
    func test_legacy_widget_snapshot_has_no_live_lease() throws {
        let value = try record()
        let legacy = WidgetSnapshot(schemaVersion: 1, sourceId: source, receivedAtMs: 3000, snapshot: value.snapshot)
        XCTAssertThrowsError(try legacy.validate())
        XCTAssertFalse(legacy.isLive(atMs: 3000))
        XCTAssertFalse(legacy.isCached(atMs: 3000))
        let oldSchemaWithLease = WidgetSnapshot(schemaVersion: 1, sourceId: source, receivedAtMs: 3000,
                                                snapshot: value.snapshot, validUntilMs: 48_000)
        XCTAssertFalse(oldSchemaWithLease.isCached(atMs: 3000))
        try isolated { store in
            let path = store.directory.appendingPathComponent("display-widget-v1.json")
            try JSONEncoder().encode(oldSchemaWithLease).write(to: path)
            XCTAssertThrowsError(try store.loadCached(atMs: 3000))
        }
    }

}
