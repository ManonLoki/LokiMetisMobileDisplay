package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** 所有调用由同一网络owner串行执行，只有commit成功才能回共享核心生成ACK。 */
class AndroidPairingStore(context: Context, private val deviceId: String) {
    private val preferences = context.applicationContext.getSharedPreferences("lan_pairing", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val alias = "loki-metris-display-lan-v1"
    private val committed = CommittedRecords(preferences.all.mapValues { (id, value) ->
        check(MdnsProtocol.isCanonicalDeviceId(id) && value is String && value.length <= 8192) { "pairing_storage_invalid" }
        value
    }.also { check(it.size <= 64) { "pairing_storage_invalid" } })

    /** 密钥只存Android Keystore；配对秘密使用带双端身份AAD的AES-GCM密文。 */
    private fun key(create: Boolean): SecretKey {
        val existing = keyStore.getKey(alias, null)
        if (existing is SecretKey) return existing
        check(create) { "pairing_key_unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generateKey()
        }
    }

    /** 自读磁盘不创建密钥，坏记录显式失败，不能静默重配或恢复可信零状态。 */
    fun load(clientId: String): JSONObject? {
        require(MdnsProtocol.isCanonicalDeviceId(clientId))
        val raw = committed.snapshot()[clientId] ?: return null
        return decode(clientId, raw)
    }

    private fun decode(clientId: String, raw: String): JSONObject {
        check(raw.length <= 8192) { "pairing_storage_invalid" }
        TerminalJsonBoundary.validateObject(raw)
        val envelope = JSONObject(raw)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
        check(iv.size == 12) { "pairing_storage_invalid" }
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, iv))
        cipher.updateAAD("LokiMetris/mobile-store/1/$clientId/$deviceId".toByteArray(Charsets.UTF_8))
        val bytes = cipher.doFinal(Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP))
        val material = try {
            val text = Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            TerminalJsonBoundary.validateObject(text); JSONObject(text)
        } finally { bytes.fill(0) }
        check(material.getString("clientId") == clientId && material.getString("deviceId") == deviceId) { "pairing_storage_invalid" }
        return material
    }

    /** 返回true只表示系统私有首选项确已同步提交，异常交调用方返回stored=false。 */
    fun save(material: JSONObject): Boolean {
        val clientId = material.getString("clientId")
        check(MdnsProtocol.isCanonicalDeviceId(clientId) && material.getString("deviceId") == deviceId) { "pairing_storage_invalid" }
        check(clientId in committed.snapshot() || committed.snapshot().size < 64) { "pairing_storage_full" }
        return committed.update(clientId, encode(material), ::persist)
    }

    /** 导出只有已提交的主配对材料，恢复码由系统安全随机数单独生成。 */
    fun exportRecovery(): AndroidPairingRecovery.Exported = AndroidPairingRecovery.export(deviceId,
        clientIds().sorted().map { requireNotNull(load(it)) })

    /** 恢复先在内存用目标身份封装，journal 只接触本机 Keystore 密文。 */
    internal fun encryptedRecoveryRecords(payload: PairingRecoveryCodec.Payload): Map<String, String> {
        PairingRecoveryCodec.validate(payload)
        require(payload.deviceId == deviceId) { "pairing_recovery_identity" }
        return payload.materials.associate { it.clientId to encode(JSONObject(it.fields())) }
    }

    internal fun recoverySnapshot(): Map<String, String> = committed.snapshot()

    /** 回放前逐条解密并验证，损坏journal不能先写配对或替换身份。 */
    internal fun recoveryPayload(records: Map<String, String> = committed.snapshot()): PairingRecoveryCodec.Payload {
        val materials = records.toSortedMap().map { (id, raw) ->
            require(MdnsProtocol.isCanonicalDeviceId(id)) { "pairing_recovery_invalid" }
            val value = decode(id, raw)
            PairingRecoveryCodec.material(value.keys().asSequence().associateWith { value.get(it) })
        }
        return PairingRecoveryCodec.Payload(deviceId, materials).also(PairingRecoveryCodec::validate)
    }

    internal fun commitRecoveryRecords(records: Map<String, String>): Boolean {
        val existing = committed.snapshot()
        check(existing.isEmpty() || existing == records) { "pairing_recovery_conflict" }
        return committed.replaceAll(records, ::persist)
    }

    private fun encode(material: JSONObject): String {
        val clientId = material.getString("clientId")
        check(MdnsProtocol.isCanonicalDeviceId(clientId) && material.getString("deviceId") == deviceId) { "pairing_storage_invalid" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        cipher.updateAAD("LokiMetris/mobile-store/1/$clientId/$deviceId".toByteArray(Charsets.UTF_8))
        val bytes = material.toString().toByteArray(Charsets.UTF_8)
        check(bytes.size <= 8192) { "pairing_storage_invalid" }
        val encrypted = try { cipher.doFinal(bytes) } finally { bytes.fill(0) }
        return JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP)).toString()
    }

    /** 只枚举有界UUID索引，不批量解密或把秘密发到界面。 */
    fun clientIds(): Set<String> {
        val values = committed.snapshot().keys
        check(values.size <= 64 && values.all(MdnsProtocol::isCanonicalDeviceId)) { "pairing_storage_invalid" }
        return values.toSet()
    }

    /** 用户明确忘记该桌面后只移除对应应用私有记录。 */
    fun forget(clientId: String): Boolean {
        require(MdnsProtocol.isCanonicalDeviceId(clientId))
        return committed.update(clientId, null, ::persist)
    }
    /** commit(false)也会改变系统内存；每次写完整权威映射，清除此前失败写入的临时内存。 */
    private fun persist(values: Map<String, String>): Boolean {
        val edit = preferences.edit().clear()
        values.forEach { (id, envelope) -> edit.putString(id, envelope) }
        return edit.commit()
    }

}
