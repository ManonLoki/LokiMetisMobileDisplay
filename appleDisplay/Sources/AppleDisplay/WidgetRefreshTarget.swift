import Foundation
import SharedLogic
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

    /// 构造与解码共用的边界检查：版本、ID、私有主机、端口与密钥格式。
    func validate() throws {
        guard version == 1, SharedValidation.validId(sourceId), SharedValidation.validId(deviceId), sourceId != deviceId,
              SharedValidation.validId(generation), (1...65535).contains(port), Self.validHost(host),
              WidgetHTTPBinary.decode(key, field: .key) != nil else {
            throw WidgetSnapshotError.invalid
        }
        _ = try requestURL()
    }

    /// 固定协议、端口和路径，调用方不能把凭据送往重定向或广告携带的 URL。
    func requestURL() throws -> URL {
        guard Self.validHost(host), (1...65535).contains(port) else { throw WidgetSnapshotError.invalid }
        var parts = URLComponents()
        parts.scheme = WidgetHttpPolicy.shared.SCHEME
        parts.host = host.contains(":") ? "[" + host + "]" : host
        parts.port = port
        parts.path = WidgetHttpPolicy.shared.PATH
        guard let url = parts.url else { throw WidgetSnapshotError.invalid }
        return url
    }

    /// 重复同步不撤销在途请求；地址、设备或独立密钥变化才切换代次。
    func sameConnection(as other: Self) -> Bool {
        guard let connection, let candidate = other.connection else { return false }
        return connection.sameConnection(other: candidate)
    }

    private var connection: RefreshConnection? {
        guard let version = Int32(exactly: version), let port = Int32(exactly: port) else { return nil }
        return RefreshConnection(version: version, sourceId: sourceId, deviceId: deviceId,
            host: host, port: port, key: key)
    }


    private static func validHost(_ host: String) -> Bool {
        guard WidgetEndpointRules.shared.validHostText(host: host) else { return false }
        if host.contains(":") {
            let pieces = host.split(separator: "%", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return false }
            if pieces.count == 2 {
                guard WidgetEndpointRules.shared.validIPv6Scope(scope: String(pieces[1])) else { return false }
            }
            var address = in6_addr()
            guard String(pieces[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
            let bytes = withUnsafeBytes(of: address) { $0.map { KotlinInt(value: Int32($0)) } }
            return WidgetEndpointRules.shared.isPrivateAddress(bytes: bytes)
        }
        if WidgetEndpointRules.shared.isPrivateIPv4Literal(host: host) { return true }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard name.hasSuffix(".local") else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }

}
