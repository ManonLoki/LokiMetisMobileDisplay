import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AppleDisplay

/// 临时目录与测试专用密钥覆盖来源切换、旧响应和真实文件锁，不访问设备凭据。
final class WidgetRefreshStoreTests: XCTestCase {
    private let source = "12345678-1234-4234-8234-123456789abc"
    private let other = "12345678-1234-4234-8234-123456789abd"
    private let device = "12345678-1234-4234-8234-123456789abe"
    private var key: String { Data(repeating: 42, count: 32).base64EncodedString() }

    private func target(host: String = "192.168.1.10", sourceId: String? = nil) throws -> WidgetRefreshTarget {
        try WidgetRefreshTarget(sourceId: sourceId ?? source, deviceId: device, host: host, port: 8123, key: key)
    }

    private func record(at time: Int64 = 3000, sourceId: String? = nil) throws -> WidgetSnapshot {
        let json = #"{"type":"snapshot","snapshot":{"version":1,"tokens":null,"tokenError":null,"hooksAvailable":true,"hooks":[]}}"#
        return try WidgetSnapshot.authenticatedMessage(Data(json.utf8), sourceId: sourceId ?? source, receivedAtMs: time)
    }

    private func isolated(_ body: (WidgetSnapshotStore) throws -> Void) throws {
        let directory = try temporaryFolder()
        try body(WidgetSnapshotStore(directory: directory))
    }

    func test_target_accepts_local_addresses_and_uses_fixed_endpoint() throws {
        for host in ["192.168.1.10", "10.0.0.1", "172.16.0.1", "169.254.1.1", "127.0.0.1", "::1", "fd00::1", "fe80::1%en0", "loki.local", "loki.local."] {
            let value = try target(host: host)
            let url = try value.requestURL()
            XCTAssertEqual(url.scheme, "http")
            XCTAssertEqual(url.port, 8123)
            XCTAssertEqual(url.path, "/api/widget/v1/snapshot")
            XCTAssertNil(url.user)
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
        }
        XCTAssertEqual(try target(host: "LOKI.local").host, "loki.local")
    }

    func test_target_rejects_nonlocal_or_url_shaped_addresses_and_invalid_credentials() throws {
        for host in ["8.8.8.8", "172.32.0.1", "0.0.0.0", "255.255.255.255", "192.168.01.1", "example.com", "loki.local.evil", "http://loki.local", "loki.local/path", "loki.local:80", "user@loki.local", "loki..local", "-loki.local", "::", "ff02::1", "2001:db8::1", "::ffff:8.8.8.8", "fe80::1%../en0", "fe80::1%", "[::1]"] {
            XCTAssertThrowsError(try target(host: host), host)
        }
        XCTAssertThrowsError(try WidgetRefreshTarget(sourceId: source, deviceId: device, host: "127.0.0.1", port: 0, key: key))
        XCTAssertThrowsError(try WidgetRefreshTarget(sourceId: source, deviceId: source, host: "127.0.0.1", port: 8123, key: key))
        XCTAssertThrowsError(try WidgetRefreshTarget(sourceId: source.uppercased(), deviceId: device, host: "127.0.0.1", port: 8123, key: key))
        XCTAssertThrowsError(try WidgetRefreshTarget(sourceId: source, deviceId: device, host: "127.0.0.1", port: 8123, key: "invalid"))
    }

    func test_target_rotation_preserves_identical_generation_and_rejects_old_response() throws {
        try isolated { store in
            XCTAssertNil(try store.loadRefreshTarget())
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: target())
            let initial = try XCTUnwrap(store.loadRefreshTarget())
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: target())
            let same = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertEqual(initial, same)
            XCTAssertEqual(try store.loadRefreshTarget(), initial)
            XCTAssertTrue(try store.saveFetchedSnapshot(record(), for: initial))
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: target(host: "192.168.1.11"))
            let changed = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertNotEqual(initial.generation, changed.generation)
            XCTAssertFalse(try store.saveFetchedSnapshot(record(at: 5000), for: initial))
            XCTAssertEqual(try store.load().receivedAtMs, 3000)
            XCTAssertTrue(try store.saveFetchedSnapshot(record(at: 5000), for: changed))
        }
    }

    /// Codable 绕过构造器的损坏整数也不能在跨语言映射时截断碰撞或崩溃。
    func test_decoded_out_of_range_connection_fields_fail_comparison_safely() throws {
        let valid = try target()
        let data = try SharedJSON.encoder.encode(valid)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["version", "port"] {
            for value in [Int.min, Int.max] {
                var object = original
                object[field] = value
                let corrupt = try SharedJSON.decoder.decode(WidgetRefreshTarget.self,
                    from: JSONSerialization.data(withJSONObject: object))
                XCTAssertThrowsError(try corrupt.validate())
                XCTAssertFalse(corrupt.sameConnection(as: valid))
                XCTAssertFalse(corrupt.sameConnection(as: corrupt))
            }
        }
    }

    func test_switch_revokes_target_even_without_snapshot_and_forgetting_is_source_specific() throws {
        try isolated { store in
            // 模拟旧摘要已被清理但授权文件仍存在的盘面。
            try WidgetStoreFixture.writeTarget(target(), to: store)
            let initial = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertThrowsError(try store.load())
            try store.selectSource(other)
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertFalse(try store.saveFetchedSnapshot(record(), for: initial))
            try store.saveAuthenticatedSnapshot(record(sourceId: other), refreshTarget: target(sourceId: other))
            let selected = try XCTUnwrap(store.loadRefreshTarget())
            try store.forgetSource(source)
            XCTAssertEqual(try store.loadRefreshTarget(), selected)
            XCTAssertEqual(try store.load().sourceId, other)
            try store.forgetSource(other)
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertThrowsError(try store.load())
            XCTAssertFalse(try store.saveFetchedSnapshot(record(sourceId: other), for: selected))
        }
    }

    func test_clear_revokes_credentials_and_cached_summary() throws {
        try isolated { store in
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: target())
            let initial = try XCTUnwrap(store.loadRefreshTarget())
            try store.selectSource(source)
            XCTAssertEqual(try store.loadRefreshTarget(), initial)
            try store.clear(); try store.clear()
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertThrowsError(try store.load())
        }
    }

    func test_fetch_does_not_replace_newer_app_snapshot_or_wrong_source() throws {
        try isolated { store in
            try store.saveAuthenticatedSnapshot(record(at: 5000), refreshTarget: target())
            let initial = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertFalse(try store.saveFetchedSnapshot(record(at: 4000), for: initial))
            XCTAssertFalse(try store.saveFetchedSnapshot(record(at: 6000), for: initial, startedAtMs: 4000))
            XCTAssertThrowsError(try store.saveFetchedSnapshot(record(at: 6000, sourceId: other), for: initial))
            XCTAssertEqual(try store.load().receivedAtMs, 5000)
            XCTAssertTrue(try store.saveFetchedSnapshot(record(at: 6000), for: initial, startedAtMs: 5500))
        }
    }

    func test_authenticated_commit_replaces_source_and_retires_unsupported_target() throws {
        try isolated { store in
            let first = try target()
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: first)
            let previous = try XCTUnwrap(store.loadRefreshTarget())
            try store.saveAuthenticatedSnapshot(record(at: 4000, sourceId: other), refreshTarget: target(sourceId: other))
            XCTAssertEqual(try store.load().sourceId, other)
            XCTAssertEqual(try store.loadRefreshTarget()?.sourceId, other)
            XCTAssertFalse(try store.saveFetchedSnapshot(record(at: 5000), for: previous))
            try store.saveAuthenticatedSnapshot(record(at: 5000, sourceId: other), refreshTarget: nil)
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertEqual(try store.load().receivedAtMs, 5000)
        }
    }

    func test_newer_http_facts_survive_heartbeat_and_delayed_authenticated_publish() throws {
        try isolated { store in
            let initial = try target()
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: initial)
            let selected = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertTrue(try store.saveFetchedSnapshot(record(at: 5000), for: selected))
            XCTAssertFalse(try store.saveIfNotOlder(record(at: 3000)))
            XCTAssertFalse(try store.saveIfNotOlder(record(at: 6000, sourceId: other)))
            try store.saveAuthenticatedSnapshot(record(at: 4000), refreshTarget: target())
            XCTAssertEqual(try store.load().receivedAtMs, 5000)
            XCTAssertEqual(try store.loadRefreshTarget(), selected)
            XCTAssertTrue(try store.saveIfNotOlder(record(at: 6000)))
            XCTAssertEqual(try store.load().receivedAtMs, 6000)
        }
    }

    func test_full_phone_cache_survives_expiry_and_extension_refresh_updates_the_same_cache() throws {
        try isolated { store in
            let summary = try record(at: 3000)
            let snapshot = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil,
                hooksAvailable: true, hooks: [], assets: [], catalogError: nil)
            let full = PhoneDisplayCache(envelope: WatchSnapshotEnvelope(version: 1, phoneId: device,
                sourceId: source, phoneReceivedAtMs: 3000, snapshot: snapshot), summaryOnly: false)
            try store.saveAuthenticatedSnapshot(summary, refreshTarget: target(), displayCache: full)
            XCTAssertEqual(try store.loadDisplayCache(), full)
            XCTAssertNotNil(try store.loadCached(atMs: 3000 + WidgetSnapshot.leaseMs * 100))
            let selected = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertTrue(try store.saveFetchedSnapshot(record(at: 5000), for: selected))
            let refreshed = try XCTUnwrap(store.loadDisplayCache())
            XCTAssertTrue(refreshed.summaryOnly)
            XCTAssertEqual(refreshed.envelope.phoneReceivedAtMs, 5000)
            XCTAssertEqual(refreshed.envelope.phoneId, device)
            try store.saveAuthenticatedSnapshot(summary, refreshTarget: target(), displayCache: full)
            XCTAssertEqual(try store.loadDisplayCache(), refreshed)
        }
    }

    func test_equal_timestamp_prefers_full_cache_and_switch_or_forget_removes_it() throws {
        try isolated { store in
            let summary = try record()
            let full = PhoneDisplayCache(envelope: try PhoneDisplayCache.summary(summary, phoneId: device).envelope,
                summaryOnly: false)
            try store.saveAuthenticatedSnapshot(summary, refreshTarget: target(), displayCache: full)
            let selected = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertTrue(try store.saveFetchedSnapshot(summary, for: selected))
            XCTAssertEqual(try store.loadDisplayCache(), full)
            try store.selectSource(source)
            XCTAssertEqual(try store.loadDisplayCache(), full)
            try store.forgetSource(other)
            XCTAssertEqual(try store.loadDisplayCache(), full)
            try store.selectSource(other)
            XCTAssertNil(try store.loadDisplayCache())
            try store.saveAuthenticatedSnapshot(summary, refreshTarget: target(), displayCache: full)
            try store.forgetSource(source)
            XCTAssertNil(try store.loadDisplayCache())
        }
    }

    func test_summary_commit_recovery_never_relabels_old_full_content_with_new_time() throws {
        try isolated { store in
            let summary = try record()
            let full = PhoneDisplayCache(envelope: try PhoneDisplayCache.summary(summary, phoneId: device).envelope,
                summaryOnly: false)
            try store.saveAuthenticatedSnapshot(summary, refreshTarget: target(), displayCache: full)
            // 模拟两次原子写之间进程结束：摘要已更新，完整投影仍旧。
            try WidgetStoreFixture.writeSnapshot(record(at: 8000), to: store)
            let recovered = try XCTUnwrap(store.loadDisplayCache())
            XCTAssertTrue(recovered.summaryOnly)
            XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 8000)
            XCTAssertEqual(recovered.envelope.snapshot.assets, [])
        }
    }

    func test_corrupt_targets_recover_by_authentication_and_http_never_follows_symlinks() throws {
        try isolated { store in
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: nil)
            let path = store.directory.appendingPathComponent("display-widget-refresh-v1.json")
            try Data("broken".utf8).write(to: path)
            XCTAssertThrowsError(try store.loadRefreshTarget())
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: target())
            let replacement = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertEqual(try store.loadRefreshTarget(), replacement)
            try FileManager.default.removeItem(at: path)
            let sentinel = store.directory.appendingPathComponent("untouched")
            try Data("original".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
            XCTAssertThrowsError(try store.loadRefreshTarget())
            XCTAssertThrowsError(try store.saveFetchedSnapshot(record(at: 5000), for: replacement))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
            XCTAssertEqual(try store.load().receivedAtMs, 3000)

            // 新认证可以撤销旧链接并重建普通目标文件，不能跟随链接写入外部正文。
            let authenticated = try target()
            try store.saveAuthenticatedSnapshot(record(), refreshTarget: authenticated)
            XCTAssertEqual(try store.loadRefreshTarget(), authenticated)
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertEqual(values.isSymbolicLink, false)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
            XCTAssertEqual(try store.load().receivedAtMs, 3000)
        }
    }

    func test_store_mutation_waits_for_existing_file_lock() throws {
        try isolated { store in
            let path = store.directory.appendingPathComponent("display-widget.lock").path
            let descriptor = path.withCString { open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
            let finished = DispatchSemaphore(value: 0)
            let value = try record()
            DispatchQueue.global().async {
                do { try store.saveAuthenticatedSnapshot(value, refreshTarget: nil) }
                catch { XCTFail("Store write failed: \(error)") }
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(try store.load(), value)
        }
    }

    func test_symlink_lock_is_not_followed() throws {
        try isolated { store in
            let sentinel = store.directory.appendingPathComponent("untouched")
            try Data("original".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("display-widget.lock"), withDestinationURL: sentinel)
            XCTAssertThrowsError(try store.saveAuthenticatedSnapshot(record(), refreshTarget: nil))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
        }
    }
}
