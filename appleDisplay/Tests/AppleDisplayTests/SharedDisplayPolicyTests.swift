import Foundation
import XCTest
@testable import AppleDisplay

/// DTO 仍保留原生 Codable 格式；跨语言边界拒绝超出 Kotlin Int 范围的恶意数值。
final class SharedDisplayPolicyTests: XCTestCase {
    func test_untrusted_integer_extremes_are_invalid_without_trapping() throws {
        for value in [Int.min, Int.max] {
            let hook = WidgetHook(agent: "codex", slot: value, behavior: .running)
            let summary = WidgetDisplaySnapshot(version: 1, tokens: nil, tokenError: nil,
                hooksAvailable: true, hooks: [hook])
            XCTAssertThrowsError(try summary.validate())
            let version = WidgetDisplaySnapshot(version: value, tokens: nil, tokenError: nil,
                hooksAvailable: false, hooks: [])
            XCTAssertThrowsError(try version.validate())
            let window = ProviderQuotaWindow(kind: "weekly", usedTenths: value, resetAtUnix: nil)
            XCTAssertThrowsError(try window.validate(kind: "weekly"))
        }
        let oversized = LanDisplaySnapshot.Asset(hash: String(repeating: "a", count: 64),
            mime: "image/png", length: UInt64.max)
        XCTAssertFalse(oversized.isValid)
    }

    func test_shared_projection_and_computed_fields_do_not_change_encoded_payload() throws {
        let amount = WidgetAmount(total: "18446744073709551615", availability: .available,
            completeness: .partial, confidence: .derived)
        let tokens = WidgetTokens(day: .init(date: "2026-10-22", zone: "Asia/Shanghai", startMs: 0, endMs: 1000),
            observedMs: 1, all: amount, agents: [.init(agent: "claude-code", amount: amount)])
        let before = try SharedJSON.sortedEncoder.encode(tokens)
        XCTAssertEqual(WidgetUsageRow.project(tokens: tokens, quota: nil, enabledAgents: nil).map(\.displayName), ["Claude Code", "Cursor"])
        XCTAssertEqual(amount.compactText, "18446744073.71B")
        XCTAssertEqual(amount.exactText, "18,446,744,073,709,551,615")
        XCTAssertEqual(amount.quality, "部分·估算")
        XCTAssertEqual(try SharedJSON.sortedEncoder.encode(tokens), before)
        XCTAssertEqual(try SharedJSON.decoder.decode(WidgetTokens.self, from: before), tokens)
    }
}
