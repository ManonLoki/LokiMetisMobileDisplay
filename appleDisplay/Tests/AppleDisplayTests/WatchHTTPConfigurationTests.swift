import Foundation
import XCTest
@testable import AppleDisplay

final class WatchHTTPConfigurationTests: XCTestCase {
    private let phone = "12345678-1234-4abc-8def-123456789abc"
    private let desktop = "22345678-1234-4abc-8def-123456789abc"
    private let other = "32345678-1234-4abc-8def-123456789abc"

    private func target(deviceId: String? = nil) throws -> WidgetRefreshTarget {
        try WidgetRefreshTarget(sourceId: desktop, deviceId: deviceId ?? phone, host: "192.168.1.20",
            port: 8123, key: Data(repeating: 42, count: 32).base64EncodedString())
    }

    private func configuration() throws -> WatchHTTPConfiguration {
        try WatchHTTPConfiguration(phoneId: phone, target: target())
    }

    /// 两端编码器的键顺序不同也不能导致相同配置不停创建新修订。
    func test_configuration_fingerprint_is_stable_and_rpc_preserves_revision() throws {
        let value = try WatchHTTPConfiguration(phoneId: phone, target: target(), revision: UInt64.max)
        let unordered = try JSONEncoder().encode(value)
        let decoded = try WatchHTTPConfiguration.decode(unordered)
        XCTAssertEqual(try value.encoded(), try decoded.encoded())
        var request = WatchRPC("requestSync")
        request.configurationRevision = value.revision
        request.configurationHash = WatchProtocol.hash(try value.encoded())
        let received = try WatchProtocol.request(WatchProtocol.encode(request))
        XCTAssertEqual(received.configurationRevision, UInt64.max)
        XCTAssertEqual(received.configurationHash, request.configurationHash)
        var reply = WatchRPCReply("http"); reply.configuration = value
        XCTAssertEqual(try WatchProtocol.reply(WatchProtocol.encode(reply)).configuration, value)
    }

    private func summary(sourceId: String? = nil, tokens: WidgetTokens? = nil,
                         tokenError: String? = nil, hooksAvailable: Bool = true,
                         hooks: [WidgetHook] = []) -> WidgetSnapshot {
        WidgetSnapshot(schemaVersion: 2, sourceId: sourceId ?? desktop, receivedAtMs: 1000,
            snapshot: WidgetDisplaySnapshot(version: 1, tokens: tokens, tokenError: tokenError,
                hooksAvailable: hooksAvailable, hooks: hooks), validUntilMs: 46_000)
    }

    func test_configuration_round_trip_binds_target_to_phone_identity() throws {
        let value = try configuration()
        let data = try value.encoded()
        XCTAssertLessThanOrEqual(data.count, WatchHTTPConfiguration.maxBytes)
        XCTAssertEqual(try WatchHTTPConfiguration.decode(data), value)
        XCTAssertEqual(value.target?.deviceId, value.phoneId)
        XCTAssertThrowsError(try WatchHTTPConfiguration(phoneId: other, target: target()))
        XCTAssertThrowsError(try WatchHTTPConfiguration(phoneId: phone, target: target(deviceId: other)))
        for invalid in ["invalid", phone.uppercased(), SharedValidation.zeroId] {
            XCTAssertThrowsError(try WatchHTTPConfiguration(phoneId: invalid, target: nil))
        }
        XCTAssertThrowsError(try WatchHTTPConfiguration(version: 2, phoneId: phone, target: nil))
    }

    func test_revocation_is_explicit_null_and_missing_target_is_invalid() throws {
        let revoked = try WatchHTTPConfiguration(phoneId: phone, target: nil)
        let data = try revoked.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["target"] is NSNull)
        XCTAssertEqual(try WatchHTTPConfiguration.decode(data), revoked)
        let incomplete = try JSONSerialization.data(withJSONObject: ["version": 1, "phoneId": phone])
        XCTAssertThrowsError(try WatchHTTPConfiguration.decode(incomplete))
        XCTAssertThrowsError(try WatchSnapshotEnvelope.fromHTTP(summary(), configuration: revoked))
    }

    func test_revision_is_required_exact_unsigned_and_round_trips_without_precision_loss() throws {
        let value = try WatchHTTPConfiguration(phoneId: phone, target: target(), revision: UInt64.max)
        let data = try value.encoded()
        XCTAssertEqual(try WatchHTTPConfiguration.decode(data), value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try configuration().encoded()) as? [String: Any])
        object.removeValue(forKey: "revision")
        XCTAssertThrowsError(try WatchHTTPConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
        for invalid in [-1, 0.5] {
            object["revision"] = invalid
            XCTAssertThrowsError(try WatchHTTPConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
        }
    }

    func test_revision_orders_configuration_and_revocation_without_reviving_old_authorization() throws {
        let initial = try WatchHTTPConfiguration(phoneId: phone, target: target(), revision: 1)
        let changedTarget = try WidgetRefreshTarget(sourceId: desktop, deviceId: phone, host: "192.168.1.21",
            port: 8123, key: Data(repeating: 42, count: 32).base64EncodedString())
        let changed = try WatchHTTPConfiguration(phoneId: phone, target: changedTarget, revision: 2)
        let revoked = try WatchHTTPConfiguration(phoneId: phone, target: nil, revision: 3)
        XCTAssertTrue(initial.supersedes(nil))
        XCTAssertTrue(changed.supersedes(initial))
        XCTAssertTrue(revoked.supersedes(changed))
        XCTAssertFalse(initial.supersedes(revoked))
        XCTAssertFalse(changed.supersedes(revoked))
        let reauthorized = try WatchHTTPConfiguration(phoneId: phone, target: changedTarget, revision: 4)
        XCTAssertTrue(reauthorized.supersedes(revoked))
        XCTAssertTrue(revoked.supersedes(revoked))
    }

    func test_equal_revision_accepts_only_identical_payload_and_new_phone_has_independent_counter() throws {
        let initial = try WatchHTTPConfiguration(phoneId: phone, target: target(), revision: 50)
        let different = try WatchHTTPConfiguration(phoneId: phone, target: nil, revision: 50)
        XCTAssertTrue(initial.supersedes(initial))
        XCTAssertFalse(different.supersedes(initial))
        XCTAssertFalse(initial.supersedes(different))
        let newPhone = try WatchHTTPConfiguration(phoneId: other, target: target(deviceId: other), revision: 0)
        XCTAssertTrue(newPhone.supersedes(initial))
    }

    /// Swift 保留 u64 原值与 Codable 字段，共享策略决定相同连接去重和最大修订的撤销接纳。
    func test_shared_policy_stabilizes_generation_and_preserves_extreme_revision_revocation() throws {
        let initial = try WatchHTTPConfiguration(phoneId: phone, target: target(), revision: UInt64.max - 1)
        let regenerated = try target()
        let stable = WatchHTTPConfiguration.stableTarget(regenerated, previous: initial)
        XCTAssertEqual(stable, initial.target)
        XCTAssertFalse(WatchHTTPConfiguration.needsPublication(previous: initial, target: stable, forceRevision: false))
        XCTAssertTrue(WatchHTTPConfiguration.needsPublication(previous: initial, target: stable, forceRevision: true))
        let revoked = try WatchHTTPConfiguration(phoneId: phone, target: nil, revision: UInt64.max)
        XCTAssertTrue(revoked.supersedes(initial))
        XCTAssertFalse(initial.supersedes(revoked))
        let conflicting = try WatchHTTPConfiguration(phoneId: phone, target: regenerated, revision: UInt64.max)
        XCTAssertFalse(conflicting.supersedes(revoked))
        XCTAssertEqual(try WatchHTTPConfiguration.decode(revoked.encoded()), revoked)
        for version in [Int.min, Int.max] {
            XCTAssertThrowsError(try WatchHTTPConfiguration(version: version, phoneId: phone, target: nil))
        }
    }

    func test_decoding_rejects_invalid_target_identity_address_and_oversized_input() throws {
        let value = try configuration()
        let data = try value.encoded()
        let text = String(decoding: data, as: UTF8.self)
        for invalid in [text.replacingOccurrences(of: "\"phoneId\":\"\(phone)\"", with: "\"phoneId\":\"\(other)\""),
                        text.replacingOccurrences(of: "192.168.1.20", with: "8.8.8.8"),
                        text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")] {
            XCTAssertThrowsError(try WatchHTTPConfiguration.decode(Data(invalid.utf8)))
        }
        let fitting = data + Data(repeating: 32, count: WatchHTTPConfiguration.maxBytes - data.count)
        XCTAssertEqual(try WatchHTTPConfiguration.decode(fitting), value)
        XCTAssertThrowsError(try WatchHTTPConfiguration.decode(fitting + Data([32])))
    }

    func test_http_projection_preserves_exact_amount_quality_and_all_hook_states() throws {
        let amount = WidgetAmount(total: String(UInt64.max), availability: .available,
            completeness: .partial, confidence: .derived)
        let unavailable = WidgetAmount(total: nil, availability: .unavailable,
            completeness: .unknown, confidence: .suspected)
        let tokens = WidgetTokens(day: .init(date: "2026-10-21", zone: "Asia/Shanghai", startMs: 0, endMs: 1000),
            observedMs: 10, all: amount, agents: [.init(agent: "codex", amount: unavailable)])
        let behaviors: [WidgetHook.Behavior] = [.idle, .running, .asking, .error]
        let hooks = behaviors.enumerated().map { WidgetHook(agent: "codex", slot: $0.offset + 1, behavior: $0.element) }
        let value = try WatchSnapshotEnvelope.fromHTTP(summary(tokens: tokens, hooks: hooks), configuration: configuration())
        XCTAssertEqual(value.phoneId, phone)
        XCTAssertEqual(value.sourceId, desktop)
        XCTAssertEqual(value.phoneReceivedAtMs, 1000)
        XCTAssertEqual(value.snapshot.tokens, tokens)
        XCTAssertEqual(value.snapshot.tokens?.all.total, String(UInt64.max))
        XCTAssertEqual(value.snapshot.hooks.map(\.slot), [1, 2, 3, 4])
        XCTAssertEqual(value.snapshot.hooks.map(\.behavior), behaviors)
        XCTAssertEqual(value.snapshot.hooks.map(\.agent), Array(repeating: "codex", count: 4))
        XCTAssertTrue(value.snapshot.hooks.allSatisfy { $0.content.isEmpty && !$0.contentTruncated && $0.image == nil })
        XCTAssertTrue(value.snapshot.assets.isEmpty)
        XCTAssertNil(value.snapshot.catalogError)
        XCTAssertNoThrow(try value.validate())
    }

    func test_http_projection_preserves_unavailable_states_and_rejects_wrong_source_or_invalid_summary() throws {
        let configuration = try configuration()
        let value = try WatchSnapshotEnvelope.fromHTTP(
            summary(tokenError: "unavailable", hooksAvailable: false), configuration: configuration)
        XCTAssertNil(value.snapshot.tokens)
        XCTAssertEqual(value.snapshot.tokenError, "unavailable")
        XCTAssertFalse(value.snapshot.hooksAvailable)
        XCTAssertTrue(value.snapshot.hooks.isEmpty)
        XCTAssertThrowsError(try WatchSnapshotEnvelope.fromHTTP(summary(sourceId: other), configuration: configuration))
        let invalid = summary(hooks: [WidgetHook(agent: "codex", slot: 0, behavior: .running)])
        XCTAssertThrowsError(try WatchSnapshotEnvelope.fromHTTP(invalid, configuration: configuration))
    }
}
