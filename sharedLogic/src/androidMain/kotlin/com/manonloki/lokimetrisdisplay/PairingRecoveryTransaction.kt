package com.manonloki.lokimetrisdisplay

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** 先记加密journal，再写完整配对映射，最后提交身份；任何中断都能在初始化身份前回放。 */
internal class PairingRecoveryTransaction(
    private val journal: File,
    private val loadRecords: () -> Map<String, String>,
    private val saveRecords: (Map<String, String>) -> Boolean,
    private val loadIdentity: () -> String?,
    private val saveIdentity: (String) -> Boolean,
    private val validateRecords: (String, Map<String, String>) -> Unit,
) {
    /** 调用者已停止全部网络owner；有现存配对时只由上层比较完全相同的恢复请求。 */
    fun begin(targetId: String, records: Map<String, String>) {
        replay()
        val previousId = requireNotNull(loadIdentity()) { "pairing_recovery_identity" }
        require(MdnsProtocol.isCanonicalDeviceId(previousId) && MdnsProtocol.isCanonicalDeviceId(targetId)) { "pairing_recovery_identity" }
        check(loadRecords().isEmpty()) { "pairing_recovery_conflict" }
        validateMap(records); validateRecords(targetId, records)
        val bytes = RecoveryJson.encode(mapOf("version" to 1, "role" to "mobile-recovery-journal", "previousDeviceId" to previousId,
            "targetDeviceId" to targetId, "records" to records))
        check(bytes.size <= PairingRecoveryCodec.MAX_BYTES) { "pairing_recovery_too_large" }
        writeAtomic(bytes)
        replay()
    }

    /** 配对写成功而身份尚未提交时保留journal；错误不会被当作一次全新安装。 */
    fun replay() {
        if (!journal.exists()) return
        require(journal.isFile && journal.length() <= PairingRecoveryCodec.MAX_BYTES) { "pairing_recovery_journal_invalid" }
        val bytes = FileInputStream(journal).use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= PairingRecoveryCodec.MAX_BYTES) { "pairing_recovery_journal_invalid" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        val value = RecoveryJson.objectFrom(bytes)
        require(value.keys == setOf("version", "role", "previousDeviceId", "targetDeviceId", "records") &&
            value["version"] == 1 && value["role"] == "mobile-recovery-journal") { "pairing_recovery_journal_invalid" }
        val previous = value["previousDeviceId"]
        val target = value["targetDeviceId"]
        require(previous is String && target is String && MdnsProtocol.isCanonicalDeviceId(previous) && MdnsProtocol.isCanonicalDeviceId(target)) { "pairing_recovery_journal_invalid" }
        val rawRecords = value["records"]
        require(rawRecords is Map<*, *> && rawRecords.all { it.key is String && it.value is String }) { "pairing_recovery_journal_invalid" }
        val records = rawRecords.entries.associate { (key, raw) -> key as String to raw as String }
        validateMap(records)
        val identity = loadIdentity()
        check(identity == previous || identity == target) { "pairing_recovery_conflict" }
        val existing = loadRecords()
        check(existing.isEmpty() || existing == records) { "pairing_recovery_conflict" }
        validateRecords(target, records)
        // commit(false)也可能修改Preferences内存；必须重新提交整图并读回，不能跳过相同值。
        check(saveRecords(records) && loadRecords() == records) { "pairing_recovery_storage" }
        check(saveIdentity(target) && loadIdentity() == target) { "pairing_recovery_identity" }
        check(journal.delete()) { "pairing_recovery_journal_remove" }
    }

    private fun validateMap(records: Map<String, String>) {
        require(records.size in 1..PairingRecoveryCodec.MAX_RECORDS && records.all { (id, raw) ->
            MdnsProtocol.isCanonicalDeviceId(id) && raw.toByteArray(Charsets.UTF_8).size <= 8192
        }) { "pairing_recovery_journal_invalid" }
    }

    private fun writeAtomic(bytes: ByteArray) {
        val directory = requireNotNull(journal.parentFile)
        check(directory.isDirectory || directory.mkdirs()) { "pairing_recovery_storage" }
        val temporary = Files.createTempFile(directory.toPath(), ".pairing-recovery-", ".tmp").toFile()
        try {
            FileOutputStream(temporary).use { output -> output.write(bytes); output.fd.sync() }
            Files.move(temporary.toPath(), journal.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { if (temporary.exists()) check(temporary.delete()) { "pairing_recovery_temporary_remove" } }
    }
}
