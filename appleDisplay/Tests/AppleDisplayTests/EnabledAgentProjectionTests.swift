import Foundation
import class SharedLogic.AgentIdentity
import XCTest
@testable import AppleDisplay

/// 桌面开关只控制展示投影；原始统计、质量与缓存传输保留同轮事实。
final class EnabledAgentProjectionTests: XCTestCase {
    private let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let phone = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let desktopAgents = ["codex", "claudeCode", "cursor", "openCode", "workBuddy", "hermes", "openClaw",
                                 "codeBuddy", "qwenCode", "kimiCode", "qoder", "geminiCli", "gitHubCopilot", "grok"]

    private func tokens(_ names: [String] = ["codex", "claude-code", "cursor", "grok-build", "workbuddy"]) -> WidgetTokens {
        WidgetTokens(day: .init(date: "2026-10-22", zone: "Asia/Shanghai", startMs: 1000, endMs: 86_401_000),
                     observedMs: 2000,
                     all: .init(total: "18446744073709551615", availability: .available,
                                completeness: .partial, confidence: .derived),
                     agents: names.enumerated().map { index, name in
            .init(agent: name, amount: .init(total: String(index + 1), availability: .available,
                                            completeness: index == 0 ? .partial : .complete,
                                            confidence: index == 0 ? .suspected : .exact))
        })
    }

    private func quota() -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(observedAtUnix: 123, providers: ["codex", "claude", "cursor", "grok"].map { provider in
            .init(provider: provider, plan: provider == "cursor" ? "ultra" : nil,
                  fiveHour: nil,
                  weekly: provider == "cursor" ? nil : .init(kind: "weekly", usedTenths: 970, resetAtUnix: nil),
                  monthly: provider == "cursor" ? .init(kind: "monthly", usedTenths: 250, resetAtUnix: 1_900_000_000) : nil)
        })
    }

    private func full(_ enabledAgents: [String]?, tokens: WidgetTokens? = nil) -> LanDisplaySnapshot {
        LanDisplaySnapshot(version: 1, tokens: tokens, tokenError: nil, hooksAvailable: true,
            hooks: [.init(agent: "claude-code", slot: 1, behavior: .running,
                          content: "保留原始 Hook", contentTruncated: false, image: nil)],
            assets: [], catalogError: nil, providerQuota: quota(), enabledAgents: enabledAgents)
    }

    private func summary(_ enabledAgents: [String]?, tokens: WidgetTokens? = nil) -> WidgetDisplaySnapshot {
        WidgetDisplaySnapshot(version: 1, tokens: tokens, tokenError: nil, hooksAvailable: true,
            hooks: [.init(agent: "claude-code", slot: 1, behavior: .running)],
            providerQuota: quota(), enabledAgents: enabledAgents)
    }

    /// 所有网络入口从同一份完整线格式取值，额外字段会按既有规则投影到摘要。
    private func message(_ snapshot: LanDisplaySnapshot, enabledValue: Any? = nil, removeEnabled: Bool = false) throws -> [String: Any] {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedJSON.encoder.encode(snapshot)) as? [String: Any])
        if removeEnabled { raw.removeValue(forKey: "enabledAgents") }
        else if let enabledValue { raw["enabledAgents"] = enabledValue }
        return ["type": "snapshot", "snapshot": raw]
    }

    func test_only_enabled_codex_and_cursor_reach_both_display_projections() throws {
        let original = tokens()
        let enabled = ["codex", "cursor"]
        let full = full(enabled, tokens: original)
        let summary = summary(enabled, tokens: original)
        try full.validate()
        try summary.validate()

        XCTAssertEqual(full.displayTokens?.agents, [original.agents[0], original.agents[2]])
        XCTAssertEqual(summary.displayTokens, full.displayTokens)
        XCTAssertEqual(full.displayProviderQuota?.providers, [quota().providers[0], quota().providers[2]])
        XCTAssertEqual(summary.displayProviderQuota, full.displayProviderQuota)
        XCTAssertEqual(WidgetUsageRow.project(tokens: original, quota: quota(), enabledAgents: enabled), [
            .agent(original.agents[0], quota: quota().providers[0]),
            .agent(original.agents[2], quota: quota().providers[2])
        ])
        XCTAssertEqual(full.hooks.first?.agent, "claude-code")
        XCTAssertEqual(summary.hooks.first?.agent, "claude-code")
    }

    func test_disabled_cursor_never_reappears_as_quota_or_default_zero() {
        let original = tokens(["codex", "claude-code"])
        let expected: [WidgetUsageRow] = [.agent(original.agents[0], quota: quota().providers[0])]
        XCTAssertEqual(WidgetUsageRow.project(tokens: original, quota: quota(), enabledAgents: ["codex"]), expected)
        XCTAssertEqual(WidgetUsageRow.project(tokens: original, quota: nil, enabledAgents: ["codex"]), [.agent(original.agents[0], quota: nil)])
        XCTAssertTrue(WidgetUsageRow.project(tokens: tokens([]), quota: nil, enabledAgents: ["codex"]).isEmpty)
        XCTAssertEqual(WidgetUsageRow.project(tokens: tokens([]), quota: nil, enabledAgents: ["Cursor"]), [.cursorDefault])
    }

    func test_explicit_empty_list_hides_every_token_and_quota_without_clearing_raw_values() throws {
        let original = tokens()
        let full = full([], tokens: original)
        let summary = summary([], tokens: original)
        try full.validate()
        try summary.validate()

        XCTAssertEqual(full.displayTokens?.agents, [])
        XCTAssertEqual(summary.displayTokens?.agents, [])
        XCTAssertEqual(full.displayProviderQuota?.providers, [])
        XCTAssertEqual(summary.displayProviderQuota?.providers, [])
        XCTAssertTrue(WidgetUsageRow.project(tokens: original, quota: quota(), enabledAgents: []).isEmpty)
        XCTAssertEqual(full.tokens, original)
        XCTAssertEqual(full.providerQuota, quota())
    }

    func test_missing_legacy_list_keeps_all_data_and_cursor_default_behavior() throws {
        let original = tokens(["codex", "claude-code", "grok-build"])
        let full = full(nil, tokens: original)
        let summary = summary(nil, tokens: original)
        try full.validate()
        try summary.validate()

        XCTAssertEqual(full.displayTokens, original)
        XCTAssertEqual(summary.displayTokens, original)
        XCTAssertEqual(full.displayProviderQuota, quota())
        XCTAssertEqual(summary.displayProviderQuota, quota())
        XCTAssertEqual(WidgetUsageRow.project(tokens: original, quota: nil, enabledAgents: nil), [
            .agent(original.agents[0], quota: nil), .agent(original.agents[1], quota: nil),
            .cursorDefault, .agent(original.agents[2], quota: nil)
        ])
        XCTAssertEqual(WidgetUsageRow.project(tokens: tokens([]), quota: nil, enabledAgents: nil), [.cursorDefault])
    }

    func test_quota_filters_independently_when_token_snapshot_is_missing() throws {
        let full = full(["claudeCode", "grok"])
        let summary = summary(["claudeCode", "grok"])
        try full.validate()
        try summary.validate()

        XCTAssertNil(full.displayTokens)
        XCTAssertNil(summary.displayTokens)
        XCTAssertEqual(full.displayProviderQuota?.providers, [quota().providers[1], quota().providers[3]])
        XCTAssertEqual(summary.displayProviderQuota, full.displayProviderQuota)
        XCTAssertEqual(WidgetUsageRow.project(tokens: tokens([]), quota: quota(), enabledAgents: ["claudeCode", "grok"]), [
            .quota(quota().providers[1]), .quota(quota().providers[3])
        ])
    }

    func test_explicit_cursor_can_display_zero_without_fabricating_a_token_snapshot() {
        let emptyFull = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: false,
            hooks: [], assets: [], catalogError: nil, enabledAgents: ["cursor"])
        let emptySummary = WidgetDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: false,
            hooks: [], enabledAgents: ["cursor"])
        XCTAssertNil(emptyFull.displayTokens)
        XCTAssertNil(emptySummary.displayTokens)
        XCTAssertEqual(emptyFull.displayUsageRows, [.cursorDefault])
        XCTAssertEqual(emptySummary.displayUsageRows, [.cursorDefault])
        XCTAssertEqual(WidgetUsageRow.project(tokens: nil, quota: nil, enabledAgents: []), [])
        XCTAssertEqual(WidgetUsageRow.project(tokens: nil, quota: nil, enabledAgents: nil), [])
        let cursorQuota = full(["cursor"])
        XCTAssertNil(cursorQuota.displayTokens)
        XCTAssertEqual(cursorQuota.displayUsageRows, [.quota(quota().providers[2])])
        XCTAssertEqual(cursorQuota.displayUsageRows.first?.tokenText, "0")
    }

    func test_desktop_camel_case_names_match_token_and_provider_aliases() throws {
        let variants = ["CODEX", "Claude Code", "CUR-SOR", "Open Code", "work_buddy", "Hermes", "open-claw",
                        "Code Buddy", "qwen-code", "Kimi Code", "Qoder", "Gemini", "GitHub Copilot CLI", "Grok-Build"]
        let original = tokens(variants)
        let projected = summary(desktopAgents, tokens: original)
        XCTAssertTrue(AgentIdentity.shared.validEnabledAgents(enabledAgents: desktopAgents))
        try projected.validate()

        XCTAssertEqual(projected.displayTokens, original)
        XCTAssertEqual(projected.displayProviderQuota, quota())
        for (canonical, variant) in zip(desktopAgents, variants) {
            XCTAssertTrue(AgentIdentity.shared.isEnabled(agent: variant, enabledAgents: [canonical]), "\(variant) must match \(canonical)")
            XCTAssertTrue(AgentIdentity.shared.isEnabled(agent: canonical, enabledAgents: [variant]), "\(canonical) must match \(variant)")
        }
        let rows = WidgetUsageRow.project(tokens: original, quota: quota(), enabledAgents: desktopAgents)
        XCTAssertEqual(rows.count, desktopAgents.count)
        XCTAssertEqual(rows.compactMap(\.quotaEntry).map(\.provider), ["codex", "claude", "cursor", "grok"])
        XCTAssertFalse(rows.contains(.cursorDefault))
        XCTAssertTrue(AgentIdentity.shared.isEnabled(agent: "geminiCli", enabledAgents: ["gemini"]))
        XCTAssertTrue(AgentIdentity.shared.isEnabled(agent: "claude", enabledAgents: ["claudeCode"]))
        XCTAssertTrue(AgentIdentity.shared.isEnabled(agent: "grok", enabledAgents: ["grok-build"]))
    }

    func test_changing_enabled_list_never_recomputes_total_quality_or_serialized_tokens() throws {
        let original = tokens()
        let originalBytes = try SharedJSON.sortedEncoder.encode(original)
        var full = full(["codex"], tokens: original)
        var summary = summary(["codex"], tokens: original)

        for enabled: [String]? in [["codex"], ["cursor"], [], nil, desktopAgents] {
            full.enabledAgents = enabled
            summary.enabledAgents = enabled
            let projectedFull = try XCTUnwrap(full.displayTokens)
            let projectedSummary = try XCTUnwrap(summary.displayTokens)
            XCTAssertEqual(projectedFull.day, original.day)
            XCTAssertEqual(projectedFull.observedMs, original.observedMs)
            XCTAssertEqual(projectedFull.all, original.all)
            XCTAssertEqual(projectedSummary.all, original.all)
            XCTAssertEqual(projectedFull.all.total, "18446744073709551615")
            XCTAssertEqual(projectedFull.all.quality, "部分·估算")
            XCTAssertEqual(full.tokens, original)
            XCTAssertEqual(summary.tokens, original)
            XCTAssertEqual(try SharedJSON.sortedEncoder.encode(full.tokens), originalBytes)
            XCTAssertEqual(try SharedJSON.sortedEncoder.encode(original), originalBytes)
        }
        let codexOnly = try XCTUnwrap(self.full(["codex"], tokens: original).displayTokens?.agents.first)
        XCTAssertEqual(codexOnly.amount, original.agents[0].amount)
        XCTAssertEqual(codexOnly.amount.quality, "部分·待核对")
    }

    func test_valid_list_boundaries_include_fourteen_agents_and_sixty_four_utf8_bytes() throws {
        XCTAssertTrue(AgentIdentity.shared.validEnabledAgents(enabledAgents: nil))
        XCTAssertTrue(AgentIdentity.shared.validEnabledAgents(enabledAgents: []))
        XCTAssertTrue(AgentIdentity.shared.validEnabledAgents(enabledAgents: desktopAgents))
        XCTAssertTrue(AgentIdentity.shared.validEnabledAgents(enabledAgents: [String(repeating: "a", count: 64)]))
        XCTAssertTrue(AgentIdentity.shared.validEnabledAgents(enabledAgents: [String(repeating: "界", count: 21)]))
        XCTAssertFalse(AgentIdentity.shared.isEnabled(agent: "codex", enabledAgents: []))
        XCTAssertTrue(AgentIdentity.shared.isEnabled(agent: "custom-agent", enabledAgents: nil))
        XCTAssertFalse(AgentIdentity.shared.isEnabled(agent: "claude", enabledAgents: ["codex"]))
    }

    func test_invalid_lists_are_rejected_before_full_or_http_projection_can_be_cached() throws {
        let invalidLists: [[String]] = [
            (0..<15).map { "agent\($0)" }, [""], [" \t\n"],
            [String(repeating: "a", count: 65)], [String(repeating: "界", count: 22)],
            ["codex", "codex"], ["Claude Code", "claudeCode"],
            ["Grok Build", "grok"], ["gemini", "geminiCli"],
            ["gitHubCopilot", "GitHub Copilot CLI"], ["cursor", " CUR-SOR "]
        ]
        for enabled in invalidLists {
            XCTAssertFalse(AgentIdentity.shared.validEnabledAgents(enabledAgents: enabled), "\(enabled)")
            XCTAssertThrowsError(try full(enabled, tokens: tokens()).validate(), "\(enabled)")
            XCTAssertThrowsError(try summary(enabled, tokens: tokens()).validate(), "\(enabled)")
            let raw = try message(full(enabled, tokens: tokens()))
            XCTAssertThrowsError(try LanDisplaySnapshot.decode(raw), "\(enabled)")
            XCTAssertThrowsError(try WidgetSnapshot.authenticatedMessage(JSONSerialization.data(withJSONObject: raw),
                sourceId: source, receivedAtMs: 3000), "\(enabled)")
        }
    }

    func test_missing_null_and_empty_list_remain_distinct_through_codable_entry_points() throws {
        for (value, omitted, expected): (Any?, Bool, [String]?) in [(nil, true, nil), (NSNull(), false, nil), ([String](), false, [])] {
            let raw = try message(full(nil, tokens: tokens()), enabledValue: value, removeEnabled: omitted)
            let decodedFull = try LanDisplaySnapshot.decode(raw)
            let decodedSummary = try WidgetSnapshot.authenticatedMessage(JSONSerialization.data(withJSONObject: raw),
                sourceId: source, receivedAtMs: 3000)
            XCTAssertEqual(decodedFull.enabledAgents, expected)
            XCTAssertEqual(decodedSummary.snapshot.enabledAgents, expected)
            XCTAssertEqual(try SharedJSON.decoder.decode(LanDisplaySnapshot.self,
                from: SharedJSON.encoder.encode(decodedFull)).enabledAgents, expected)
            XCTAssertEqual(try SharedJSON.decoder.decode(WidgetDisplaySnapshot.self,
                from: SharedJSON.encoder.encode(decodedSummary.snapshot)).enabledAgents, expected)
            XCTAssertEqual(decodedFull.displayTokens?.agents.isEmpty, expected == [] ? true : false)
            XCTAssertEqual(decodedSummary.snapshot.displayProviderQuota?.providers.isEmpty, expected == [] ? true : false)
        }
    }

    func test_full_http_watch_and_phone_caches_preserve_current_enabled_list() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        let target = try WidgetRefreshTarget(sourceId: source, deviceId: phone, host: "192.168.1.10", port: 12345,
            key: Data(repeating: 7, count: 32).base64EncodedString())
        let configuration = try WatchHTTPConfiguration(phoneId: phone, target: target)

        for (index, enabled) in [["codex", "cursor"], []].enumerated() {
            let receivedAtMs = Int64(3000 + index * 1000)
            let original = full(enabled, tokens: tokens())
            let raw = try message(original)
            let decodedFull = try LanDisplaySnapshot.decode(raw)
            let http = try WidgetSnapshot.authenticatedMessage(JSONSerialization.data(withJSONObject: raw),
                sourceId: source, receivedAtMs: receivedAtMs)
            let watch = try WatchSnapshotEnvelope.fromHTTP(http, configuration: configuration)
            let phoneCache = try PhoneDisplayCache.summary(http, phoneId: phone)
            let fullEnvelope = WatchSnapshotEnvelope(version: 1, phoneId: phone, sourceId: source,
                phoneReceivedAtMs: receivedAtMs, snapshot: decodedFull)
            let encodedWatch = try SharedJSON.encoder.encode(fullEnvelope)
            let assembled = WatchSnapshotAssembler()
            let id = UUID().uuidString.lowercased()
            try assembled.begin(id: id, hash: WatchProtocol.hash(encodedWatch), length: UInt64(encodedWatch.count))
            let transferred = try XCTUnwrap(assembled.accept(id: id, offset: 0, data: encodedWatch).1)

            XCTAssertEqual(http.snapshot.enabledAgents, enabled)
            XCTAssertEqual(watch.snapshot.enabledAgents, enabled)
            XCTAssertEqual(phoneCache.envelope.snapshot.enabledAgents, enabled)
            XCTAssertEqual(transferred.envelope.snapshot.enabledAgents, enabled)
            XCTAssertEqual(watch.snapshot.displayTokens, decodedFull.displayTokens)
            XCTAssertEqual(phoneCache.envelope.snapshot.displayProviderQuota, decodedFull.displayProviderQuota)
            try store.saveAuthenticatedSnapshot(http, refreshTarget: target, displayCache: phoneCache)
            XCTAssertEqual(try store.load().snapshot.enabledAgents, enabled)
            XCTAssertEqual(try store.loadDisplayCache()?.envelope.snapshot.enabledAgents, enabled)
        }
    }

    func test_http_image_merge_retains_latest_enabled_list_including_explicit_empty() throws {
        let hash = String(repeating: "a", count: 64)
        let previousSnapshot = LanDisplaySnapshot(version: 1, tokens: tokens(), tokenError: nil, hooksAvailable: true,
            hooks: [.init(agent: "claude-code", slot: 1, behavior: .running,
                          content: "旧正文", contentTruncated: false, image: hash)],
            assets: [.init(hash: hash, mime: "image/gif", length: 6)], catalogError: nil,
            providerQuota: quota(), enabledAgents: ["claudeCode"])
        let previousEnvelope = WatchSnapshotEnvelope(version: 1, phoneId: phone, sourceId: source,
            phoneReceivedAtMs: 2000, snapshot: previousSnapshot)
        let previousCache = PhoneDisplayCache(envelope: previousEnvelope, summaryOnly: false)
        try previousCache.validate()
        let target = try WidgetRefreshTarget(sourceId: source, deviceId: phone, host: "192.168.1.10", port: 12345,
            key: Data(repeating: 7, count: 32).base64EncodedString())
        let configuration = try WatchHTTPConfiguration(phoneId: phone, target: target)

        for enabled in [["codex"], []] {
            let raw = try message(full(enabled, tokens: tokens()))
            let http = try WidgetSnapshot.authenticatedMessage(JSONSerialization.data(withJSONObject: raw),
                sourceId: source, receivedAtMs: 4000)
            let watch = try WatchSnapshotEnvelope.fromHTTP(http, configuration: configuration)
                .preservingCachedHookImages(from: previousEnvelope)
            let phoneCache = try PhoneDisplayCache.summary(http, phoneId: phone, preservingImagesFrom: previousCache)

            XCTAssertEqual(watch.snapshot.enabledAgents, enabled)
            XCTAssertEqual(phoneCache.envelope.snapshot.enabledAgents, enabled)
            XCTAssertEqual(watch.snapshot.hooks.first?.image, hash)
            XCTAssertEqual(phoneCache.envelope.snapshot.hooks.first?.image, hash)
            XCTAssertEqual(watch.snapshot.hooks.first?.cachedImageReceivedAtMs, 2000)
            XCTAssertEqual(phoneCache.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 2000)
            XCTAssertEqual(watch.snapshot.displayTokens?.agents.map(\.agent), enabled)
            XCTAssertEqual(phoneCache.envelope.snapshot.displayProviderQuota?.providers.map(\.provider), enabled)
            XCTAssertEqual(watch.snapshot.tokens, previousSnapshot.tokens)
        }
    }
}
