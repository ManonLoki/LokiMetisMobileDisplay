package com.manonloki.lokimetrisdisplay.storage

import com.manonloki.lokimetrisdisplay.rules.TerminalValueRules

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
            if (parts.size != 2 || !TerminalValueRules.validDeviceId(parts[0]) ||
                !TerminalValueRules.validDeviceId(parts[1]) || parts[0] == parts[1]) return invalid()
            identities += parts[1]
        }
        return when (identities.size) {
            0 -> IdentityRecovery(IdentityRecoveryStatus.MISSING, null)
            1 -> IdentityRecovery(IdentityRecoveryStatus.RECOVERED, identities.single())
            else -> IdentityRecovery(IdentityRecoveryStatus.AMBIGUOUS, null)
        }
    }
}
