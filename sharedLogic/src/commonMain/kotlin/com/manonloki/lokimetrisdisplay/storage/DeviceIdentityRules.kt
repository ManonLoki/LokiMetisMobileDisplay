package com.manonloki.lokimetrisdisplay

enum class IdentityRecoveryStatus { MISSING, RECOVERED, AMBIGUOUS, INVALID_INDEX }
data class IdentityRecovery(val status: IdentityRecoveryStatus, val deviceId: String?)

/** 系统确认稳定身份缺失后才传入配对索引；读取失败不能被转换为空集合。 */
object DeviceIdentityRules {
    fun recoverFromPairingAccounts(accounts: List<String>): IdentityRecovery {
        fun invalid() = IdentityRecovery(IdentityRecoveryStatus.INVALID_INDEX, null)
        if (accounts.size > 64 || accounts.toSet().size != accounts.size) return invalid()
        val identities = mutableSetOf<String>()
        for (account in accounts) {
            val parts = account.split('.')
            if (parts.size != 2 || !MdnsProtocol.isCanonicalDeviceId(parts[0]) ||
                !MdnsProtocol.isCanonicalDeviceId(parts[1]) || parts[0] == parts[1]) return invalid()
            identities += parts[1]
        }
        return when (identities.size) {
            0 -> IdentityRecovery(IdentityRecoveryStatus.MISSING, null)
            1 -> IdentityRecovery(IdentityRecoveryStatus.RECOVERED, identities.single())
            else -> IdentityRecovery(IdentityRecoveryStatus.AMBIGUOUS, null)
        }
    }
}

/** 线协议与本机记录共同使用的格式规则，系统负责密码运算和实际文件访问。 */
object TerminalValueRules {
    const val ZERO_ID = "00000000-0000-0000-0000-000000000000"
    fun isCanonicalUUID(value: String): Boolean = value == ZERO_ID || MdnsProtocol.isCanonicalDeviceId(value)
    fun validDeviceId(value: String): Boolean = MdnsProtocol.isCanonicalDeviceId(value)
    fun validContentHash(value: String): Boolean = validHash(value)
    fun containsControl(value: String): Boolean = value.any { it.code in 0..31 || it.code in 127..159 }
}
