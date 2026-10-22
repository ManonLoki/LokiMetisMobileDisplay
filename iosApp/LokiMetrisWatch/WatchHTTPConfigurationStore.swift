import Foundation
import Security

/// 只读连接配置保存在本表 Keychain；设备备份和日志均不携带授权密钥。
enum WatchHTTPConfigurationStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "LokiMetris.watch-http.v1",
         kSecAttrAccount as String: "paired-phone"]
    }

    /// 读取手机下发的只读 HTTP 配置；不存在时返回 nil。
    static func load() throws -> WatchHTTPConfiguration? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw WidgetSnapshotError.unavailable }
        return try WatchHTTPConfiguration.decode(data)
    }

    /// 以 Keychain 更新或新增的返回状态确认提交；失败抛给引擎撤销旧持久授权。
    static func save(_ configuration: WatchHTTPConfiguration) throws {
        let data = try configuration.encoded()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            let item = query.merging(attributes) { _, next in next }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw WidgetSnapshotError.unavailable }
        } else if updated != errSecSuccess { throw WidgetSnapshotError.unavailable }
    }

    /// 删除持久配置；用于配置写入失败时尽力撤销旧授权。
    static func discard() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WidgetSnapshotError.unavailable }
    }
}
