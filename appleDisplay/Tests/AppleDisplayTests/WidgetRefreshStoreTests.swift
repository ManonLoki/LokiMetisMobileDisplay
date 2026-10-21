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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
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
            let initial = try store.saveRefreshTarget(target())
            let same = try store.saveRefreshTarget(target())
            XCTAssertEqual(initial, same)
            XCTAssertEqual(try store.loadRefreshTarget(), initial)
            XCTAssertTrue(try store.saveFetchedSnapshot(record(), for: initial))
            let changed = try store.saveRefreshTarget(target(host: "192.168.1.11"))
            XCTAssertNotEqual(initial.generation, changed.generation)
            XCTAssertFalse(try store.saveFetchedSnapshot(record(at: 5000), for: initial))
            XCTAssertEqual(try store.load().receivedAtMs, 3000)
            XCTAssertTrue(try store.saveFetchedSnapshot(record(at: 5000), for: changed))
        }
    }

    func test_switch_revokes_target_even_without_snapshot_and_forgetting_is_source_specific() throws {
        try isolated { store in
            let initial = try store.saveRefreshTarget(target())
            try store.selectSource(other)
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertFalse(try store.saveFetchedSnapshot(record(), for: initial))
            try store.save(record(sourceId: other))
            let selected = try store.saveRefreshTarget(target(sourceId: other))
            try store.forgetSource(source)
            XCTAssertEqual(try store.loadRefreshTarget(), selected)
            XCTAssertEqual(try store.load().sourceId, other)
            try store.forgetSource(other)
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertThrowsError(try store.load())
            XCTAssertFalse(try store.saveFetchedSnapshot(record(sourceId: other), for: selected))
        }
    }

    func test_clear_revokes_credentials_and_clear_target_keeps_cached_summary() throws {
        try isolated { store in
            let initial = try store.saveRefreshTarget(target())
            try store.save(record())
            try store.selectSource(source)
            XCTAssertEqual(try store.loadRefreshTarget(), initial)
            try store.clearRefreshTarget(sourceId: other)
            XCTAssertEqual(try store.loadRefreshTarget(), initial)
            try store.clearRefreshTarget(sourceId: source)
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertEqual(try store.load().receivedAtMs, 3000)
            XCTAssertFalse(try store.saveFetchedSnapshot(record(at: 5000), for: initial))
            try store.saveRefreshTarget(initial)
            try store.clear(); try store.clear()
            XCTAssertNil(try store.loadRefreshTarget())
            XCTAssertThrowsError(try store.load())
        }
    }

    func test_fetch_does_not_replace_newer_app_snapshot_or_wrong_source() throws {
        try isolated { store in
            let initial = try store.saveRefreshTarget(target())
            try store.save(record(at: 5000))
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

    func test_corrupt_and_symlink_targets_fail_without_touching_snapshot() throws {
        try isolated { store in
            try store.save(record())
            let path = store.directory.appendingPathComponent("display-widget-refresh-v1.json")
            try Data("broken".utf8).write(to: path)
            XCTAssertThrowsError(try store.loadRefreshTarget())
            let replacement = try store.saveRefreshTarget(target())
            XCTAssertEqual(try store.loadRefreshTarget(), replacement)
            try FileManager.default.removeItem(at: path)
            let sentinel = store.directory.appendingPathComponent("untouched")
            try Data("original".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
            XCTAssertThrowsError(try store.loadRefreshTarget())
            XCTAssertThrowsError(try store.saveRefreshTarget(target()))
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
                do { try store.save(value) }
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
            XCTAssertThrowsError(try store.save(record()))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
        }
    }
}
