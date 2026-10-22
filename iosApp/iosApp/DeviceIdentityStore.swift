import Foundation
import Security

/// 本机身份与配对秘密分别保存。私有、不同步、不可迁移至另一设备；不使用设备指纹认证。
final class DeviceIdentityStore {
    private static let lock = NSLock()
    private let service = (Bundle.main.bundleIdentifier ?? "com.manonloki.lokimetrisdisplay") + ".lan-identity-v1"
    private let account = "device-id"

    /// 读取本机身份；进程内加锁，避免并发首次创建出两个 UUID。
    func load() throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        // 配对文件功能已移除；废弃日志不再阻塞启动，也不能切换已提交的设备身份。
        var obsolete = query
        obsolete[kSecAttrAccount as String] = "pending-recovery-v1"
        _ = SecItemDelete(obsolete as CFDictionary)
        return try DeviceIdentityPolicy.load(readIdentity: readIdentity,
            pairingAccounts: PairingStore.identityAccounts, saveIdentity: saveIdentity)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    /// 按账户读取私有钥匙串身份，核对可访问属性与 UUID 格式；损坏不能当成缺失。
    private func readIdentity() throws -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceIdentityFailure.keychainUnavailable }
        guard let row = item as? [String: Any],
              row[kSecAttrService as String] as? String == service,
              row[kSecAttrAccount as String] as? String == account,
              row[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
              let data = row[kSecValueData as String] as? Data, data.count == 36,
              let identity = String(data: data, encoding: .utf8), SharedValidation.validId(identity)
        else { throw DeviceIdentityFailure.invalidIdentity }
        return identity
    }

    /// 仅添加缺失项，绝不覆盖既有身份。并发首次写入只能接受已保存的同一个 UUID。
    private func saveIdentity(_ identity: String) throws {
        guard SharedValidation.validId(identity) else { throw DeviceIdentityFailure.invalidIdentity }
        var addition = query
        addition[kSecValueData as String] = Data(identity.utf8)
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addition as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try readIdentity() == identity else { throw DeviceIdentityFailure.conflictingIdentity }
        } else if status != errSecSuccess { throw DeviceIdentityFailure.keychainWriteFailed }
    }
}

extension DeviceIdentityFailure {
    var userMessage: String {
        switch self {
        case .keychainUnavailable:
            return "无法访问本机身份钥匙串。请先解锁设备，再重新打开应用；不会创建替代身份。"
        case .keychainWriteFailed:
            return "未能将设备身份保存到钥匙串。请解锁设备并检查可用空间后重试；原配对未修改。"
        case .ambiguousPairedIdentity:
            return "发现多组旧设备身份，无法安全选择连接身份。请保留现有数据并检查身份存储；原配对未修改。"
        case .conflictingIdentity:
            return "钥匙串中已存在另一个设备身份。请保留现有数据后重新打开应用；不会自动改绑原配对。"
        case .invalidPairingIndex:
            return "旧配对身份记录不完整或格式异常，无法安全恢复设备身份；原配对未修改。"
        case .invalidIdentity:
            return "设备身份记录损坏，无法继续连接。请保留现有数据并检查身份存储。"
        }
    }
}
