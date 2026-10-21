import Foundation
import Security

/// 配对秘密只放本机首次解锁后可读Keychain；不启用iCloud同步或公共共享组。
final class PairingStore {
    enum Failure: Error { case invalid; case storage }
    private let deviceId: String
    private let service = (Bundle.main.bundleIdentifier ?? "com.manonloki.lokimetrisdisplay") + ".lan-pairing-v1"
    init(deviceId: String) { self.deviceId = deviceId }

    private func query(_ clientId: String) throws -> [String: Any] {
        guard UUID(uuidString: clientId)?.uuidString.lowercased() == clientId else { throw Failure.invalid }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: clientId + "." + deviceId,
                kSecAttrSynchronizable as String: false]
    }

    /// 读取失败不回退空记录；只有errSecItemNotFound代表尚未配对。
    func load(_ clientId: String) throws -> [String: Any]? {
        var search = try query(clientId)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 8192,
              let material = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              material["clientId"] as? String == clientId,
              material["deviceId"] as? String == deviceId else { throw Failure.storage }
        return material
    }

    /// 只枚举本应用服务中属于当前设备的账户属性，不读取其他身份或批量暴露秘密。
    func clientIds() throws -> Set<String> {
        let search: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = item as? [[String: Any]], rows.count <= 64 else { throw Failure.storage }
        let suffix = "." + deviceId
        var result: Set<String> = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String, account.hasSuffix(suffix) else { continue }
            let id = String(account.dropLast(suffix.count))
            guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.storage }
            result.insert(id)
        }
        return result
    }

    /// 前台解锁期间迁移旧记录，让系统之后唤醒App时能认证局域网桌面。
    /// 逐条验证双端身份与原始数据边界，仅修改可访问属性，不重写或删除秘密。
    func prepareForBackgroundRefresh() throws {
        for clientId in try clientIds().sorted() {
            var search = try query(clientId)
            search[kSecReturnAttributes as String] = true
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(search as CFDictionary, &item)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let row = item as? [String: Any],
                  row[kSecAttrService as String] as? String == service,
                  row[kSecAttrAccount as String] as? String == clientId + "." + deviceId,
                  let data = row[kSecValueData as String] as? Data, data.count <= 8192,
                  let material = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  material["clientId"] as? String == clientId,
                  material["deviceId"] as? String == deviceId,
                  let accessibility = row[kSecAttrAccessible as String] as? String else { throw Failure.storage }
            if accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String { continue }
            guard accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String else { throw Failure.storage }
            var exact = try query(clientId)
            exact[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let update = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            guard SecItemUpdate(exact as CFDictionary, update as CFDictionary) == errSecSuccess else { throw Failure.storage }
        }
    }

    /// 只有OS调用确实成功才返回true；调用方须把原commitId交还共享核心再取得ACK。
    func save(_ material: [String: Any]) throws -> Bool {
        guard let clientId = material["clientId"] as? String,
              material["deviceId"] as? String == deviceId else { throw Failure.invalid }
        let data = try JSONSerialization.data(withJSONObject: material)
        guard data.count <= 8192 else { throw Failure.invalid }
        let search = try query(clientId)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(search as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var addition = search
        addition.merge(update) { _, new in new }
        return SecItemAdd(addition as CFDictionary, nil) == errSecSuccess
    }

    /// 用户忘记该桌面后只删除精确双端身份的私有配对记录。
    func forget(_ clientId: String) throws -> Bool {
        let status = SecItemDelete(try query(clientId) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
