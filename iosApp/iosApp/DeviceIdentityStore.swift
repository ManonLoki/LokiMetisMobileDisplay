import Foundation
import Security

/// 本机身份与配对秘密分别保存。私有、不同步、不可迁移至另一设备；不使用设备指纹认证。
final class DeviceIdentityStore {
    private static let lock = NSLock()
    private let service = (Bundle.main.bundleIdentifier ?? "com.manonloki.lokimetrisdisplay") + ".lan-identity-v1"
    private let account = "device-id"
    private let recoveryAccount = "pending-recovery-v1"
    private let manager = FileManager.default

    func load() throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> String {
        if let pending = try readRecovery() {
            let saved = try readIdentity()
            guard saved == pending.previousId || saved == pending.targetId else { throw DeviceIdentityFailure.recoveryConflict }
            guard saved == pending.targetId else { throw DeviceIdentityFailure.recoveryPending }
            do { try PairingStore(deviceId: pending.targetId).verifyRecovery(fingerprint: pending.fingerprint) }
            catch { throw DeviceIdentityFailure.recoveryPending }
            try removeLegacyFile(allowedIds: [pending.previousId, pending.targetId])
            try clearRecovery()
        }
        return try DeviceIdentityPolicy.load(readIdentity: readIdentity, readLegacyFile: readLegacyFile,
            legacyPairingAccounts: PairingStore.legacyIdentityAccounts, saveIdentity: saveIdentity)
    }

    /// 调用方必须先停止网络 owner。可在后台队列执行，不依赖 MainActor 或界面状态。
    /// 空库检查→记录无秘密日志→配对逐条写入读回→移除旧文件→原子提交身份→清日志。
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

    private func verifyRestoredPayloadUnlocked(_ payload: PairingRecovery.Payload) throws -> String {
        // 失败兜底不得借 load 的首次安装/迁移路径生成或选取一个身份。
        guard try readIdentity() == payload.deviceId else { throw DeviceIdentityFailure.recoveryConflict }
        let identity = try loadUnlocked()
        guard identity == payload.deviceId, try readRecovery() == nil else { throw DeviceIdentityFailure.recoveryPending }
        // 只比较已选择身份的完整组；显式选择成功后其他旧身份仍可原样保留。
        try PairingStore(deviceId: identity).verifyExistingRecoverySelection(materials: payload.materials)
        return identity
    }

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
                guard try readLegacyFile() == nil else { throw DeviceIdentityFailure.conflictingIdentity }
                try store.verifyExistingRecoverySelection(materials: payload.materials)
                try saveIdentity(payload.deviceId)
                guard try readIdentity() == payload.deviceId else { throw DeviceIdentityFailure.recoveryWriteFailed }
                return payload.deviceId
            }
            guard let saved, currentDeviceId == saved else { throw DeviceIdentityFailure.recoveryConflict }
            let legacy = try readLegacyFile()
            guard legacy == nil || legacy == saved else { throw DeviceIdentityFailure.conflictingIdentity }
            try store.checkRecoveryDestination(materials: payload.materials, resuming: false)
            pending = try DeviceIdentityRecovery(previousId: saved, targetId: payload.deviceId, fingerprint: fingerprint)
            try saveRecovery(pending)
        }
        try store.importRecoveryMaterials(payload.materials)
        try removeLegacyFile(allowedIds: [pending.previousId, pending.targetId])
        try commitRestoredIdentity(pending)
        try clearRecovery()
        return payload.deviceId
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private func readIdentity() throws -> String? {
        guard let data = try readKeychainData(account: account, maximumBytes: 36) else { return nil }
        guard data.count == 36, let identity = String(data: data, encoding: .utf8), SharedValidation.validId(identity)
        else { throw DeviceIdentityFailure.invalidIdentity }
        return identity
    }

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

    private func readRecovery() throws -> DeviceIdentityRecovery? {
        guard let data = try readKeychainData(account: recoveryAccount, maximumBytes: 1024) else { return nil }
        guard let pending = try? SharedJSON.decoder.decode(DeviceIdentityRecovery.self, from: data)
        else { throw DeviceIdentityFailure.recoveryConflict }
        try pending.validate()
        return pending
    }

    private func saveRecovery(_ pending: DeviceIdentityRecovery) throws {
        try pending.validate()
        var addition = query
        addition[kSecAttrAccount as String] = recoveryAccount
        addition[kSecValueData as String] = try SharedJSON.sortedEncoder.encode(pending)
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess,
              try readRecovery() == pending else { throw DeviceIdentityFailure.recoveryWriteFailed }
    }

    private func clearRecovery() throws {
        var search = query; search[kSecAttrAccount as String] = recoveryAccount
        let status = SecItemDelete(search as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceIdentityFailure.recoveryWriteFailed }
    }

    private func commitRestoredIdentity(_ pending: DeviceIdentityRecovery) throws {
        let saved = try readIdentity()
        if saved == pending.targetId { return }
        guard saved == pending.previousId else { throw DeviceIdentityFailure.recoveryConflict }
        let update: [String: Any] = [kSecValueData as String: Data(pending.targetId.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess,
              try readIdentity() == pending.targetId else { throw DeviceIdentityFailure.recoveryWriteFailed }
    }

    private func removeLegacyFile(allowedIds: Set<String>) throws {
        guard let identity = try readLegacyFile() else { return }
        guard allowedIds.contains(identity) else { throw DeviceIdentityFailure.conflictingIdentity }
        do {
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
            try manager.removeItem(at: support.appendingPathComponent("Discovery/device-id"))
        } catch where SharedFiles.isMissing(error) {}
        catch { throw DeviceIdentityFailure.legacyStorageUnavailable }
    }

    /// 旧文件只读迁移：缺失和读取失败不同，拒绝链接、目录、超长文本与非规范 UUID。
    private func readLegacyFile() throws -> String? {
        do {
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
            let directory = support.appendingPathComponent("Discovery", isDirectory: true)
            let directoryAttributes = try manager.attributesOfItem(atPath: directory.path)
            guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
                throw DeviceIdentityFailure.legacyStorageInvalid
            }
            let file = directory.appendingPathComponent("device-id")
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == 36 else {
                throw DeviceIdentityFailure.legacyStorageInvalid
            }
            let data = try Data(contentsOf: file)
            guard data.count == 36, let identity = String(data: data, encoding: .utf8), SharedValidation.validId(identity)
            else { throw DeviceIdentityFailure.legacyStorageInvalid }
            return identity
        } catch where SharedFiles.isMissing(error) { return nil }
        catch let error as DeviceIdentityFailure { throw error }
        catch { throw DeviceIdentityFailure.legacyStorageUnavailable }
    }
}

extension DeviceIdentityFailure {
    var userMessage: String {
        switch self {
        case .keychainUnavailable:
            return "无法访问本机身份钥匙串。请先解锁设备，再重新打开应用；不会创建替代身份。"
        case .keychainWriteFailed:
            return "未能将设备身份保存到钥匙串。请解锁设备并检查可用空间后重试；原配对未修改。"
        case .ambiguousLegacyIdentity:
            return "发现多组旧设备身份。请导入对应身份的恢复包及恢复码，明确选择与全部旧配对精确匹配的一组；原配对未修改。"
        case .conflictingIdentity:
            return "钥匙串身份与旧设备身份不一致。恢复包不能覆盖此冲突，请保留现有数据并检查原身份文件；不会自动改绑原配对。"
        case .invalidPairingIndex:
            return "旧配对身份记录不完整或格式异常，无法安全恢复设备身份；原配对未修改。"
        case .legacyStorageUnavailable:
            return "无法读取原设备身份文件。请解锁设备并检查存储后重新打开应用；不会创建替代身份。"
        case .invalidIdentity, .legacyStorageInvalid:
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
