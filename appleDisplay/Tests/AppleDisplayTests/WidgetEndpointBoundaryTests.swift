import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AppleDisplay

/// 原生地址解析与共享端点策略共同决定接纳范围；仅构造 URL，不连接这些地址。
final class WidgetEndpointBoundaryTests: XCTestCase {
    private func target(_ host: String) throws -> WidgetRefreshTarget {
        try WidgetRefreshTarget(sourceId: "12345678-1234-4abc-8def-123456789abc",
            deviceId: "22345678-1234-4abc-8def-123456789abc", host: host, port: 12345,
            key: Data(repeating: 7, count: 32).base64EncodedString())
    }

    /// 通过 inet_pton 与真实 SharedLogic 分类，域名和大小写仍按 Apple 既有合同处理。
    func test_native_endpoint_mapping_preserves_local_names_and_private_address_ranges() throws {
        for host in ["desktop.local", "desktop.local.", "DESKTOP.LOCAL.", "10.0.0.1", "172.31.255.255",
                     "169.254.1.1", "::1", "FC00::1", "fdff::1", "fe80::1%en0",
                     "fe80::1%" + String(repeating: "a", count: 32), "::ffff:192.168.1.1", "::ffff:c0a8:101"] {
            let value = try target(host)
            XCTAssertEqual(value.host, host.lowercased())
            XCTAssertNoThrow(try value.requestURL())
        }
        for host in ["example.com", "loki.local.evil", "loki..local", "-loki.local", "desktop.local..",
                     "192.168.01.1", "256.1.1.1", "::", "ff02::1", "fec0::1", "::192.168.1.1",
                     "::ffff:8.8.8.8", "fe80::1%../en0", "fe80::1%",
                     "fe80::1%" + String(repeating: "a", count: 33), "[::1]"] {
            XCTAssertThrowsError(try target(host), host)
        }
    }

    /// mapped IPv6 的文本语法由系统解析器决定，不套用独立 IPv4 的规范十进制要求。
    func test_mapped_private_ipv4_syntax_preserves_system_parser_acceptance() throws {
        let host = "::ffff:192.168.01.1"
        var address = in6_addr()
        let acceptedBySystem = host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        XCTAssertEqual((try? target(host)) != nil, acceptedBySystem)
    }

    func test_decoding_does_not_apply_the_constructor_lowercase_normalization() throws {
        let original = try target("DESKTOP.LOCAL.")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedJSON.encoder.encode(original)) as? [String: Any])
        fields["host"] = "DESKTOP.LOCAL."
        let decoded = try SharedJSON.decoder.decode(WidgetRefreshTarget.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try decoded.validate())
    }
}
