import Foundation
import XCTest
@testable import AppleDisplay

/// 排序只影响 UI 投影；上游身份、数字、质量与序列化顺序保持不变。
final class UsageDisplayOrderTests: XCTestCase {
    private func tokens(_ names: [String]) -> WidgetTokens {
        let amount = WidgetAmount(total: "18446744073709551615", availability: .available,
                                  completeness: .partial, confidence: .derived)
        return WidgetTokens(day: .init(date: "2026-10-22", zone: "Asia/Shanghai", startMs: 1000, endMs: 86401000),
                            observedMs: 2000, all: amount, agents: names.enumerated().map { index, name in
            .init(agent: name, amount: index == 0 ? amount : .init(total: String(index), availability: .available,
                                                                completeness: .complete, confidence: .exact))
        })
    }

    private func quota(_ providers: [String]) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(observedAtUnix: 123, providers: providers.map { provider in
            ProviderQuotaEntry(provider: provider, plan: "pro", fiveHour: nil,
                               weekly: provider == "cursor" ? nil : .init(kind: "weekly", usedTenths: 970, resetAtUnix: nil),
                               monthly: provider == "cursor" ? .init(kind: "monthly", usedTenths: 250, resetAtUnix: 1900000000) : nil)
        })
    }

    func test_display_agents_prioritize_cursor_and_keep_other_order_and_exact_payload() throws {
        let names = ["WorkBuddy", "Hermes", "Grok-Build", "Custom", "Cursor", "Claude Code", "codex", "work-buddy"]
        let original = tokens(names)
        try original.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(original)

        XCTAssertEqual(original.displayAgents.map(\.agent),
                       ["codex", "Claude Code", "Cursor", "Grok-Build", "Hermes", "Custom", "WorkBuddy", "work-buddy"])
        XCTAssertEqual(original.agents.map(\.agent), names)
        XCTAssertEqual(original.displayAgents.first { $0.agent == "WorkBuddy" }, original.agents.first)
        XCTAssertEqual(original.displayAgents.first { $0.agent == "WorkBuddy" }?.amount.text, "18446744073709551615")
        XCTAssertEqual(original.displayAgents.first { $0.agent == "WorkBuddy" }?.amount.quality, "部分·估算")
        XCTAssertEqual(try encoder.encode(original), before)
        XCTAssertEqual(try SharedJSON.decoder.decode(WidgetTokens.self, from: before), original)
    }

    func test_quota_only_cursor_displays_zero_before_grok_and_workbuddy_without_changing_tokens() throws {
        let original = tokens(["workbuddy", "hermes", "grok-build", "claude-code", "codex"])
        let quota = quota(["codex", "claude", "cursor", "grok"])
        try quota.validate()
        let rows = original.displayRows(quota: quota)

        XCTAssertEqual(rows.map(\.id), ["agent:codex", "agent:claude-code", "default:cursor", "agent:grok-build", "agent:hermes", "agent:workbuddy"])
        XCTAssertEqual(rows[2], .cursorDefault(quota: quota.providers[2]))
        XCTAssertEqual(rows[2].tokenText, "0")
        XCTAssertNil(rows[2].tokenAmount)
        XCTAssertEqual(rows[0], .agent(original.agents[4], quota: quota.providers[0]))
        XCTAssertEqual(rows.last, .agent(original.agents[0], quota: nil))
        let projectedAgents = rows.compactMap { row -> WidgetTokens.Agent? in
            if case .agent(let agent, _) = row { return agent }
            return nil
        }
        XCTAssertEqual(projectedAgents, original.displayAgents)
        XCTAssertFalse(projectedAgents.contains { $0.agent == "cursor" })
        XCTAssertEqual(original.agents[0].amount.text, "18446744073709551615")
    }

    func test_cursor_token_and_quota_share_one_row() throws {
        let original = tokens(["workbuddy", "cursor", "codex"])
        let quota = quota(["codex", "cursor"])
        let rows = original.displayRows(quota: quota)

        XCTAssertEqual(rows, [.agent(original.agents[2], quota: quota.providers[0]),
                              .agent(original.agents[1], quota: quota.providers[1]),
                              .agent(original.agents[0], quota: nil)])
    }

    func test_quota_only_and_token_only_snapshots_preserve_real_rows() {
        let quota = quota(["claude", "cursor", "grok"])
        XCTAssertEqual(tokens([]).displayRows(quota: quota),
                       [.quota(quota.providers[0]), .cursorDefault(quota: quota.providers[1]), .quota(quota.providers[2])])
        let original = tokens(["workbuddy", "custom", "cursor"])
        XCTAssertEqual(original.displayRows(quota: nil), original.displayAgents.map { .agent($0, quota: nil) })
        XCTAssertEqual(tokens([]).displayRows(quota: nil), [.cursorDefault(quota: nil)])
    }

    func test_missing_cursor_is_visible_before_workbuddy_and_does_not_change_serialized_tokens() throws {
        let original = tokens(["workbuddy", "grok", "codex"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(original)
        let rows = original.displayRows(quota: nil)

        XCTAssertEqual(rows.map(\.displayName), ["Codex", "Cursor", "Grok", "WorkBuddy"])
        XCTAssertEqual(rows[1], .cursorDefault(quota: nil))
        XCTAssertEqual(rows[1].tokenText, "0")
        XCTAssertNil(rows[1].quotaEntry)
        XCTAssertNil(rows[1].tokenAmount)
        XCTAssertEqual(original.agents.count, 3)
        XCTAssertEqual(try encoder.encode(original), before)
        XCTAssertEqual(original.all.total, "18446744073709551615")
    }

    func test_cursor_missing_amount_displays_zero_and_real_zero_or_usage_is_retained() {
        for availability in [WidgetAmount.Availability.noRecords, .unavailable] {
            let amount = WidgetAmount(total: nil, availability: availability, completeness: .unknown, confidence: .exact)
            let row = WidgetUsageRow.agent(.init(agent: "Cursor", amount: amount), quota: nil)
            XCTAssertEqual(row.tokenText, "0")
            XCTAssertEqual(row.tokenAmount, amount)
            XCTAssertNil(row.tokenAmount?.total)
        }
        for total in ["0", "12345"] {
            let amount = WidgetAmount(total: total, availability: .available, completeness: .complete, confidence: .exact)
            let row = WidgetUsageRow.agent(.init(agent: "cursor", amount: amount), quota: nil)
            XCTAssertEqual(row.tokenText, total)
        }
        let original = tokens(["CUR-SOR", "workbuddy"])
        XCTAssertEqual(original.displayRows(quota: nil).count, 2)
    }
}
