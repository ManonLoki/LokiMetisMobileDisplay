import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 已认证桌面授予的独立只读摘要凭据；不包含主连接的配对秘密或任意远端路径。
struct WidgetRefreshTarget: Codable, Equatable {
    let version: Int
    let sourceId: String
    let deviceId: String
    let host: String
    let port: Int
    let key: String
    let generation: String

    init(version: Int = 1, sourceId: String, deviceId: String, host: String, port: Int, key: String,
         generation: String = UUID().uuidString.lowercased()) throws {
        self.version = version; self.sourceId = sourceId; self.deviceId = deviceId
        self.host = host.lowercased(); self.port = port; self.key = key; self.generation = generation
        try validate()
    }

    func validate() throws {
        guard version == 1, Self.validId(sourceId), Self.validId(deviceId), sourceId != deviceId,
              Self.validId(generation), (1...65535).contains(port), Self.validHost(host),
              let bytes = Data(base64Encoded: key), bytes.count == 32, bytes.base64EncodedString() == key else {
            throw WidgetSnapshotError.invalid
        }
        _ = try requestURL()
    }

    /// 固定协议、端口和路径，调用方不能把凭据送往重定向或广告携带的 URL。
    func requestURL() throws -> URL {
        guard Self.validHost(host), (1...65535).contains(port) else { throw WidgetSnapshotError.invalid }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host.contains(":") ? "[" + host + "]" : host
        parts.port = port
        parts.path = "/api/widget/v1/snapshot"
        guard let url = parts.url else { throw WidgetSnapshotError.invalid }
        return url
    }

    /// 重复同步不撤销在途请求；地址、设备或独立密钥变化才切换代次。
    func sameConnection(as other: Self) -> Bool {
        version == other.version && sourceId == other.sourceId && deviceId == other.deviceId &&
        host == other.host && port == other.port && key == other.key
    }

    static func validId(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id && id != "00000000-0000-0000-0000-000000000000"
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host == host.lowercased(),
              host.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else { return false }
        if host.contains(":") {
            let pieces = host.split(separator: "%", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return false }
            if pieces.count == 2 {
                guard !pieces[1].isEmpty, pieces[1].utf8.count <= 32,
                      pieces[1].utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { return false }
            }
            var address = in6_addr()
            guard String(pieces[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            guard bytes.contains(where: { $0 != 0 }), bytes[0] != 0xff else { return false }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return privateIPv4(Array(bytes.suffix(4)))
            }
            let loopback = bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1
            return loopback || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        let numbers = host.split(separator: ".", omittingEmptySubsequences: false)
        if numbers.count == 4, numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) {
            guard numbers.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }),
                  numbers.allSatisfy({ UInt8($0) != nil }) else { return false }
            return privateIPv4(numbers.compactMap { UInt8($0) })
        }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard name.hasSuffix(".local") else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }

    private static func privateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || bytes[0] == 127 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }
}
