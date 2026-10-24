import Foundation
import class SharedLogic.AgentIdentity
import XCTest
@testable import AppleDisplay

/// 真实线格式在手机、Widget与Watch共享解析，不依赖真实配对或网络。
final class ProviderQuotaTests: XCTestCase {
    private func message(_ providers: [[String: Any]]? = nil) -> [String: Any] {
        var snapshot: [String: Any] = ["version": 1, "tokens": NSNull(), "tokenError": NSNull(),
            "hooksAvailable": false, "hooks": [], "assets": [], "catalogError": NSNull()]
        if let providers { snapshot["providerQuota"] = ["observedAtUnix": 123, "providers": providers] }
        return ["type": "snapshot", "snapshot": snapshot]
    }
    private var weekly: [String: Any] { ["provider": "codex", "plan": "pro", "weekly": ["kind": "weekly", "usedTenths": 970, "resetAtUnix": 1900000000]] }

    /// 无五小时字段仍保留周进度，完整与HTTP摘要均保留同一额度。
    func test_weekly_only_survives_full_and_widget_decoding() throws {
        let message = message([weekly])
        let full = try LanDisplaySnapshot.decode(message)
        XCTAssertNil(full.providerQuota?.providers.first?.fiveHour)
        XCTAssertEqual(full.providerQuota?.providers.first?.weekly?.percentText, "3%")
        let bytes = try JSONSerialization.data(withJSONObject: message)
        let widget = try WidgetSnapshot.authenticatedMessage(bytes, sourceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", receivedAtMs: 1_000)
        XCTAssertEqual(widget.snapshot.providerQuota, full.providerQuota)
        let roundtrip = try SharedJSON.decoder.decode(WidgetSnapshot.self, from: SharedJSON.encoder.encode(widget))
        XCTAssertEqual(roundtrip.snapshot.providerQuota, full.providerQuota)
    }
    /// Claude 位于 Codex 与 Cursor 之间，Cursor 只有月窗口也保留，顺序错乱或错槽被拒绝。
    func test_claude_and_cursor_monthly_decode_in_catalog_order() throws {
        let claude: [String: Any] = ["provider": "claude", "fiveHour": ["kind": "fiveHour", "usedTenths": 300], "weekly": ["kind": "weekly", "usedTenths": 50]]
        let cursor: [String: Any] = ["provider": "cursor", "plan": "pro", "monthly": ["kind": "monthly", "usedTenths": 250, "resetAtUnix": 1900000000]]
        let grok: [String: Any] = ["provider": "grok", "weekly": ["kind": "weekly", "usedTenths": 0]]
        let full = try LanDisplaySnapshot.decode(message([weekly, claude, cursor, grok]))
        let providers = try XCTUnwrap(full.providerQuota?.providers)
        XCTAssertEqual(providers.map(\.label), ["Codex", "Claude", "Cursor", "Grok"])
        XCTAssertEqual(providers[1].windows.map(\.label), ["每周", "5h"])
        XCTAssertEqual(providers[2].windows.map { "\($0.label) \($0.percentText)" }, ["每月 75%"])
        XCTAssertNil(providers[0].monthly)
        XCTAssertEqual(AgentIdentity.shared.providerQuotaKey(agent: "claude-code"), "claude")
        let roundtrip = try SharedJSON.decoder.decode(ProviderQuotaSnapshot.self, from: SharedJSON.encoder.encode(full.providerQuota))
        XCTAssertEqual(roundtrip, full.providerQuota)
        XCTAssertThrowsError(try LanDisplaySnapshot.decode(message([cursor, claude])))
        var wrongSlot = cursor; wrongSlot["monthly"] = ["kind": "weekly", "usedTenths": 1]
        XCTAssertThrowsError(try LanDisplaySnapshot.decode(message([wrongSlot])))
    }
    /// 手表独立HTTP查询沿用同一摘要，不能在投影转换中丢掉额度。
    func test_watch_http_projection_keeps_quota() throws {
        let raw = try JSONSerialization.data(withJSONObject: message([weekly]))
        let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let phone = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let summary = try WidgetSnapshot.authenticatedMessage(raw, sourceId: source, receivedAtMs: 1_000)
        let target = try WidgetRefreshTarget(sourceId: source, deviceId: phone, host: "192.168.1.10", port: 12345,
            key: Data(repeating: 7, count: 32).base64EncodedString())
        let configuration = try WatchHTTPConfiguration(phoneId: phone, target: target)
        let envelope = try WatchSnapshotEnvelope.fromHTTP(summary, configuration: configuration)
        XCTAssertEqual(envelope.snapshot.providerQuota, summary.snapshot.providerQuota)
    }
    /// 旧桌面缺字段和新桌面显式空列表都合法，但不会继承历史额度。
    func test_legacy_and_empty_quota_are_distinct_valid_snapshots() throws {
        XCTAssertNil(try LanDisplaySnapshot.decode(message()).providerQuota)
        XCTAssertEqual(try LanDisplaySnapshot.decode(message([])).providerQuota?.providers.count, 0)
    }
    /// 越界、错槽、重复和身份信息不允许进入展示或共享缓存。
    func test_invalid_quota_is_rejected_at_both_entry_points() throws {
        var percent = weekly; percent["weekly"] = ["kind": "weekly", "usedTenths": 1001]
        var wrongKind = weekly; wrongKind["weekly"] = ["kind": "fiveHour", "usedTenths": 50]
        var privatePlan = weekly; privatePlan["plan"] = "user@example.com"
        for values in [[percent], [wrongKind], [privatePlan], [weekly, weekly], [["provider": "workbuddy", "weekly": ["kind": "weekly", "usedTenths": 50]]]] {
            let raw = message(values)
            XCTAssertThrowsError(try LanDisplaySnapshot.decode(raw))
            XCTAssertThrowsError(try WidgetSnapshot.authenticatedMessage(JSONSerialization.data(withJSONObject: raw), sourceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", receivedAtMs: 1_000))
        }
    }
    /// 套餐标签只改显示首字母；编码和解码仍保留桌面提供的原值。
    func test_plan_tag_capitalizes_only_first_character_without_changing_wire_value() throws {
        for (raw, shown) in [("ultra", "Ultra"), ("pro", "Pro"), ("proMAX", "ProMAX"), ("team-plus", "Team-plus")] {
            let entry = ProviderQuotaEntry(provider: "cursor", plan: raw, fiveHour: nil,
                weekly: ProviderQuotaWindow(kind: "weekly", usedTenths: 300, resetAtUnix: nil))
            XCTAssertEqual(entry.planLabel, shown)
            XCTAssertEqual(entry.displayName, "Cursor，套餐 " + shown)
            let encoded = try SharedJSON.encoder.encode(entry)
            let decoded = try SharedJSON.decoder.decode(ProviderQuotaEntry.self, from: encoded)
            XCTAssertEqual(decoded.plan, raw)
        }
        let noPlan = ProviderQuotaEntry(provider: "codex", plan: nil, fiveHour: nil,
            weekly: ProviderQuotaWindow(kind: "weekly", usedTenths: 0, resetAtUnix: nil))
        XCTAssertNil(noPlan.planLabel)
        XCTAssertEqual(noPlan.displayName, "Codex")
    }
    /// 三色阈值与耗尽/满额在各Apple终端共享整数语义。
    func test_percent_and_color_boundaries_keep_zero_balance() throws {
        for (remaining, level) in [(0,0), (200,0), (201,1), (500,1), (501,2), (1000,2)] {
            let value = ProviderQuotaWindow(kind: "weekly", usedTenths: 1000 - remaining, resetAtUnix: nil)
            try value.validate(kind: "weekly")
            XCTAssertEqual(value.level, level)
            XCTAssertEqual(value.remainingTenths, remaining)
        }
    }
}
