import Foundation
import Security

/// 配对秘密只放本机首次解锁后可读Keychain；不启用iCloud同步或公共共享组。
final class PairingStore {
    enum Failure: Error { case invalid; case storage }
    private let deviceId: String
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.manonloki.lokimetrisdisplay") + ".lan-pairing-v1" }
    private var service: String { Self.service }
    init(deviceId: String) { self.deviceId = deviceId }

    /// 重装恢复只读取私有服务中的账户属性，不读取任何配对秘密或修改其双端绑定。
    static func identityAccounts() throws -> [String] {
        let search: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw DeviceIdentityFailure.keychainUnavailable }
        guard let rows = item as? [[String: Any]], rows.count <= 64 else { throw DeviceIdentityFailure.invalidPairingIndex }
        return try rows.map { row in
            guard row[kSecAttrService as String] as? String == service,
                  let account = row[kSecAttrAccount as String] as? String else { throw DeviceIdentityFailure.invalidPairingIndex }
            return account
        }
    }

    /// 精确定位「桌面.本机」这一条钥匙串记录的查询条件。
    private func query(_ clientId: String) throws -> [String: Any] {
        guard SharedValidation.isCanonicalUUID(clientId) else { throw Failure.invalid }
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
            guard SharedValidation.isCanonicalUUID(id) else { throw Failure.storage }
            result.insert(id)
        }
        return result
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
