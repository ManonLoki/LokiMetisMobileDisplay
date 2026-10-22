import Foundation
import Security

/// 本机身份与配对秘密分别保存。私有、不同步、不可迁移至另一设备；不使用设备指纹认证。
final class DeviceIdentityStore {
    private static let lock = NSLock()
    private let service = (Bundle.main.bundleIdentifier ?? "com.manonloki.lokimetrisdisplay") + ".lan-identity-v1"
    private let account = "device-id"
    private let recoveryAccount = "pending-recovery-v1"

    /// 读取本机身份；进程内加锁，避免并发首次创建出两个 UUID。
    func load() throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try loadUnlocked()
    }

    /// 先收尾未完成的恢复事务，再按策略读取或创建身份。
    private func loadUnlocked() throws -> String {
        if let pending = try readRecovery() {
            let saved = try readIdentity()
            guard saved == pending.previousId || saved == pending.targetId else { throw DeviceIdentityFailure.recoveryConflict }
            guard saved == pending.targetId else { throw DeviceIdentityFailure.recoveryPending }
            do { try PairingStore(deviceId: pending.targetId).verifyRecovery(fingerprint: pending.fingerprint) }
            catch { throw DeviceIdentityFailure.recoveryPending }
            try clearRecovery()
        }
        return try DeviceIdentityPolicy.load(readIdentity: readIdentity,
            pairingAccounts: PairingStore.identityAccounts, saveIdentity: saveIdentity)
    }

    /// 调用方必须先停止网络 owner。可在后台队列执行，不依赖 MainActor 或界面状态。
    /// 空库检查→记录无秘密日志→配对逐条写入读回→原子提交身份→清日志。
    func restore(payload: PairingRecovery.Payload, currentDeviceId: String) throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try restoreUnlocked(payload: payload, currentDeviceId: currentDeviceId)
    }

    /// 后台完成事务并验证目标组的全部凭据，不能仅以 UUID 相同推断恢复成功。
    /// 最终提交后出现临时错误时，仅在日志已安全收尾且整包材料精确一致后视为成功。
    func restoreAndVerify(payload: PairingRecovery.Payload, currentDeviceId: String) throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try PairingRecovery.validate(deviceId: payload.deviceId, materials: payload.materials)
        do { _ = try restoreUnlocked(payload: payload, currentDeviceId: currentDeviceId) }
        catch {
            let restoreError = error
            do { return try verifyRestoredPayloadUnlocked(payload) }
            catch { throw restoreError }
        }
        return try verifyRestoredPayloadUnlocked(payload)
    }

    /// 恢复失败后的兜底核对：只有整包材料与已存身份完全一致才算成功。
    private func verifyRestoredPayloadUnlocked(_ payload: PairingRecovery.Payload) throws -> String {
        // 失败兜底不得借 load 的首次安装/重装恢复路径生成或选取一个身份。
        guard try readIdentity() == payload.deviceId else { throw DeviceIdentityFailure.recoveryConflict }
        let identity = try loadUnlocked()
        guard identity == payload.deviceId, try readRecovery() == nil else { throw DeviceIdentityFailure.recoveryPending }
        // 只比较已选择身份的完整组；显式选择成功后其他旧身份仍可原样保留。
        try PairingStore(deviceId: identity).verifyExistingRecoverySelection(materials: payload.materials)
        return identity
    }

    /// 恢复事务本体：先写日志，再导入配对，最后原子切换身份。
    private func restoreUnlocked(payload: PairingRecovery.Payload, currentDeviceId: String) throws -> String {
        let fingerprint = try PairingStore.recoveryFingerprint(deviceId: payload.deviceId, materials: payload.materials)
        let saved = try readIdentity()
        let pending: DeviceIdentityRecovery
        let store = PairingStore(deviceId: payload.deviceId)
        if let existing = try readRecovery() {
            try existing.accepts(currentId: saved, targetId: payload.deviceId, fingerprint: fingerprint)
            guard currentDeviceId.isEmpty || currentDeviceId == saved else { throw DeviceIdentityFailure.recoveryConflict }
            pending = existing
        } else {
            if saved == nil, currentDeviceId.isEmpty {
                try store.verifyExistingRecoverySelection(materials: payload.materials)
                try saveIdentity(payload.deviceId)
                guard try readIdentity() == payload.deviceId else { throw DeviceIdentityFailure.recoveryWriteFailed }
                return payload.deviceId
            }
            guard let saved, currentDeviceId == saved else { throw DeviceIdentityFailure.recoveryConflict }
            try store.checkRecoveryDestination(materials: payload.materials, resuming: false)
            pending = try DeviceIdentityRecovery(previousId: saved, targetId: payload.deviceId, fingerprint: fingerprint)
            try saveRecovery(pending)
        }
        try store.importRecoveryMaterials(payload.materials)
        try commitRestoredIdentity(pending)
        try clearRecovery()
        return payload.deviceId
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    /// 读取钥匙串中的设备身份，格式不符视为损坏而不是缺失。
    private func readIdentity() throws -> String? {
        guard let data = try readKeychainData(account: account, maximumBytes: 36) else { return nil }
        guard data.count == 36, let identity = String(data: data, encoding: .utf8), SharedValidation.validId(identity)
        else { throw DeviceIdentityFailure.invalidIdentity }
        return identity
    }

    /// 按账户读取私有钥匙串条目，并核对可访问属性与长度上限。
    private func readKeychainData(account: String, maximumBytes: Int) throws -> Data? {
        var search = query
        search[kSecAttrAccount as String] = account
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
              let data = row[kSecValueData as String] as? Data, !data.isEmpty, data.count <= maximumBytes
        else { throw DeviceIdentityFailure.invalidIdentity }
        return data
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

    /// 读取未完成的恢复日志（不含任何秘密）。
    private func readRecovery() throws -> DeviceIdentityRecovery? {
        guard let data = try readKeychainData(account: recoveryAccount, maximumBytes: 1024) else { return nil }
        guard let pending = try? SharedJSON.decoder.decode(DeviceIdentityRecovery.self, from: data)
        else { throw DeviceIdentityFailure.recoveryConflict }
        try pending.validate()
        return pending
    }

    /// 写入恢复日志并读回核对，后续步骤中断后可继续同一恢复包。
    private func saveRecovery(_ pending: DeviceIdentityRecovery) throws {
        try pending.validate()
        var addition = query
        addition[kSecAttrAccount as String] = recoveryAccount
        addition[kSecValueData as String] = try SharedJSON.sortedEncoder.encode(pending)
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess,
              try readRecovery() == pending else { throw DeviceIdentityFailure.recoveryWriteFailed }
    }

    /// 恢复完成后删除日志。
    private func clearRecovery() throws {
        var search = query; search[kSecAttrAccount as String] = recoveryAccount
        let status = SecItemDelete(search as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceIdentityFailure.recoveryWriteFailed }
    }

    /// 把设备身份从旧值原子切换为恢复包中的目标值。
    private func commitRestoredIdentity(_ pending: DeviceIdentityRecovery) throws {
        let saved = try readIdentity()
        if saved == pending.targetId { return }
        guard saved == pending.previousId else { throw DeviceIdentityFailure.recoveryConflict }
        let update: [String: Any] = [kSecValueData as String: Data(pending.targetId.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess,
              try readIdentity() == pending.targetId else { throw DeviceIdentityFailure.recoveryWriteFailed }
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
            return "发现多组旧设备身份。请导入对应身份的恢复包及恢复码，明确选择与全部旧配对精确匹配的一组；原配对未修改。"
        case .conflictingIdentity:
            return "钥匙串中已存在另一个设备身份。恢复包不能覆盖此冲突，请保留现有数据后重新打开应用；不会自动改绑原配对。"
        case .invalidPairingIndex:
            return "旧配对身份记录不完整或格式异常，无法安全恢复设备身份；原配对未修改。"
        case .invalidIdentity:
            return "设备身份记录损坏，无法继续连接。恢复包不能覆盖损坏的身份记录，请保留现有数据并检查身份存储。"
        case .recoveryPending:
            return "上次配对恢复尚未完成。请重新导入同一个恢复包及恢复码以继续；完成前不会自动连接。"
        case .recoveryConflict:
            return "恢复包与本机身份或配对记录不一致。仅允许空配对库恢复，或继续同一个未完成的恢复包。"
        case .recoveryWriteFailed:
            return "配对恢复未能完成保存。请解锁设备后重新导入同一个恢复包及恢复码以继续。"
        }
    }
}
