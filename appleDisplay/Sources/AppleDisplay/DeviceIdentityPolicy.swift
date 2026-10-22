import Foundation

/// 身份恢复只使用 UUID 与配对索引，不读取、改绑或重新生成已有配对秘密。
enum DeviceIdentityFailure: Error, Equatable {
    case invalidIdentity
    case conflictingIdentity
    case ambiguousPairedIdentity
    case invalidPairingIndex
    case keychainUnavailable
    case keychainWriteFailed
    case recoveryPending
    case recoveryConflict
    case recoveryWriteFailed
}

/// 不含配对秘密的恢复日志；旧身份只有在整包配对写入并读回后才可切换。
struct DeviceIdentityRecovery: Codable, Equatable {
    let version: Int
    let previousId: String
    let targetId: String
    let fingerprint: String

    init(previousId: String, targetId: String, fingerprint: String) throws {
        version = 1; self.previousId = previousId; self.targetId = targetId; self.fingerprint = fingerprint
        try validate()
    }

    func validate() throws {
        guard version == 1, SharedValidation.validId(previousId), SharedValidation.validId(targetId),
              SharedValidation.validHash(fingerprint) else { throw DeviceIdentityFailure.recoveryConflict }
    }

    func accepts(currentId: String?, targetId: String, fingerprint: String) throws {
        try validate()
        guard currentId == previousId || currentId == self.targetId,
              targetId == self.targetId, fingerprint == self.fingerprint else { throw DeviceIdentityFailure.recoveryConflict }
    }
}

enum DeviceIdentityPolicy {
    /// 钥匙串身份优先；重装后钥匙串仍在时，从配对索引恢复唯一身份；两者都确定缺失才首次生成。
    /// 所有读取错误向上传递，设备未解锁等临时失败不能被当成首次安装。
    static func load(
        readIdentity: () throws -> String?,
        pairingAccounts: () throws -> [String],
        saveIdentity: (String) throws -> Void,
        generateIdentity: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> String {
        if let saved = try readIdentity() {
            guard SharedValidation.validId(saved) else { throw DeviceIdentityFailure.invalidIdentity }
            return saved
        }
        let identity = try uniquePairedIdentity(accounts: pairingAccounts()) ?? generateIdentity()
        guard SharedValidation.validId(identity) else { throw DeviceIdentityFailure.invalidIdentity }
        try saveIdentity(identity)
        return identity
    }

    /// 配对账户严格为「桌面 UUID.本机 UUID」；多组身份不得按顺序、数量或最近使用时间猜测。
    static func uniquePairedIdentity(accounts: [String]) throws -> String? {
        let identities = try pairedIdentities(accounts: accounts)
        guard identities.count <= 1 else { throw DeviceIdentityFailure.ambiguousPairedIdentity }
        return identities.first
    }

    /// 从配对账户名解析出现过的本机身份集合；任何格式异常都整体拒绝。
    static func pairedIdentities(accounts: [String]) throws -> Set<String> {
        guard accounts.count <= 64 else { throw DeviceIdentityFailure.invalidPairingIndex }
        var identities: Set<String> = []
        var seen: Set<String> = []
        for account in accounts {
            let parts = account.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, SharedValidation.validId(String(parts[0])),
                  SharedValidation.validId(String(parts[1])), parts[0] != parts[1],
                  seen.insert(account).inserted else { throw DeviceIdentityFailure.invalidPairingIndex }
            identities.insert(String(parts[1]))
        }
        return identities
    }

    /// 恢复包在歧义中是用户明确的选择；必须与所选身份的完整既存配对逐项一致。
    static func verifyRecoverySelection(deviceId: String, materials: [[String: Any]], accounts: [String],
                                        storedMaterials: [[String: Any]]) throws {
        try PairingRecovery.validate(deviceId: deviceId, materials: materials)
        try PairingRecovery.validate(deviceId: deviceId, materials: storedMaterials)
        let identities = try pairedIdentities(accounts: accounts)
        guard identities.contains(deviceId) else { throw DeviceIdentityFailure.recoveryConflict }
        let suffix = "." + deviceId
        let indexedClients = Set(accounts.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
        let expectedClients = Set(materials.compactMap { $0["clientId"] as? String })
        let storedClients = Set(storedMaterials.compactMap { $0["clientId"] as? String })
        guard indexedClients == expectedClients, storedClients == expectedClients else { throw DeviceIdentityFailure.recoveryConflict }
        let order: ([String: Any], [String: Any]) -> Bool = { ($0["clientId"] as? String ?? "") < ($1["clientId"] as? String ?? "") }
        let expected = try JSONSerialization.data(withJSONObject: materials.sorted(by: order), options: [.sortedKeys])
        let stored = try JSONSerialization.data(withJSONObject: storedMaterials.sorted(by: order), options: [.sortedKeys])
        guard expected == stored else { throw DeviceIdentityFailure.recoveryConflict }
    }
}
