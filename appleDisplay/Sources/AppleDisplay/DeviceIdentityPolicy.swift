import Foundation

/// 本机身份只使用 UUID 与配对索引，不读取、改绑或重新生成已有配对秘密。
enum DeviceIdentityFailure: Error, Equatable {
    case invalidIdentity
    case conflictingIdentity
    case ambiguousPairedIdentity
    case invalidPairingIndex
    case keychainUnavailable
    case keychainWriteFailed
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
    private static func pairedIdentities(accounts: [String]) throws -> Set<String> {
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
}
