package com.manonloki.lokimetrisdisplay

import android.content.Context
import java.io.File

/** UI确认并停止网络后调用；只替换空安装，恢复旧UUID与秘密在同一可回放事务内生效。 */
class AndroidPairingRecoveryStore(context: Context) {
    private val app = context.applicationContext

    /** 回放完成后的只读核对；不能仅凭UUID相同宣称整包已恢复。 */
    fun isRestored(payload: AndroidPairingRecovery.Payload): Boolean = synchronized(lock) {
        PairingRecoveryCodec.validate(payload.value)
        val identity = app.getSharedPreferences("mdns_identity", Context.MODE_PRIVATE).getString("device_id", null)
        identity == payload.deviceId && samePayload(AndroidPairingStore(app, payload.deviceId).recoveryPayload(), payload.value)
    }

    fun restore(payload: AndroidPairingRecovery.Payload) = synchronized(lock) {
        PairingRecoveryCodec.validate(payload.value)
        replayPending(app)
        val identity = app.getSharedPreferences("mdns_identity", Context.MODE_PRIVATE).getString("device_id", null)
        require(identity != null && MdnsProtocol.isCanonicalDeviceId(identity)) { "pairing_recovery_identity" }
        val current = AndroidPairingStore(app, identity)
        if (current.recoverySnapshot().isNotEmpty()) {
            // 成功后重试同一包可无操作；不覆盖其他身份，也不覆盖已存在的不同秘密。
            check(identity == payload.deviceId && samePayload(current.recoveryPayload(), payload.value)) { "pairing_recovery_conflict" }
            return@synchronized
        }
        val target = AndroidPairingStore(app, payload.deviceId)
        val encrypted = target.encryptedRecoveryRecords(payload.value)
        transaction(app).begin(payload.deviceId, encrypted)
    }

    companion object {
        private val lock = Any()
        /** AndroidDeviceSettings必须先调用；失败向上报错，不能生成另一UUID掩盖半恢复。 */
        fun replayPending(context: Context) = synchronized(lock) { transaction(context.applicationContext).replay() }

        private fun samePayload(a: PairingRecoveryCodec.Payload, b: PairingRecoveryCodec.Payload): Boolean =
            a.deviceId == b.deviceId && a.materials.associateBy { it.clientId } == b.materials.associateBy { it.clientId }

        private fun transaction(app: Context): PairingRecoveryTransaction {
            val identity = app.getSharedPreferences("mdns_identity", Context.MODE_PRIVATE)
            val records = app.getSharedPreferences("lan_pairing", Context.MODE_PRIVATE)
            fun readRecords(): Map<String, String> = records.all.mapValues { (id, raw) ->
                check(MdnsProtocol.isCanonicalDeviceId(id) && raw is String && raw.length <= 8192) { "pairing_storage_invalid" }
                raw
            }.also { check(it.size <= 64) { "pairing_storage_invalid" } }
            return PairingRecoveryTransaction(File(app.noBackupFilesDir, "pairing-recovery-pending-v1.json"),
                loadRecords = ::readRecords,
                saveRecords = { values ->
                    val target = requireNotNull(identity.getString("device_id", null))
                    // 原始密文已由 validateRecords 使用目标UUID验证；这里一次提交完整映射。
                    AndroidPairingStore(app, target).commitRecoveryRecords(values)
                },
                loadIdentity = { identity.getString("device_id", null) },
                saveIdentity = { target -> identity.edit().putString("device_id", target).commit() },
                validateRecords = { target, values -> AndroidPairingStore(app, target).recoveryPayload(values) })
        }
    }
}
