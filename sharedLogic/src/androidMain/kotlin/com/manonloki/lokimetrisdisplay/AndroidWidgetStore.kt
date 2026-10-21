package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** 同一进程所有实例共用一把锁；摘要和加密读取配置在同一个 noBackup 文件中原子换代。 */
class AndroidWidgetStore internal constructor(
    private val directory: File,
    private val key: (create: Boolean) -> SecretKey,
    private val now: () -> Long = System::currentTimeMillis,
) {
    constructor(context: Context) : this(
        File(context.applicationContext.noBackupFilesDir, "android-widget-v1"), AndroidWidgetKeystore()::key,
    )

    private val file = File(directory, "summary-v1.bin")
    private val pending = File(directory, "summary-v1.bin.new")

    /** 只返回最近一次合法摘要，磁盘内容不恢复 LAN 在线状态。 */
    fun read(): AndroidWidgetSnapshot? = synchronized(lock) {
        runCatching { load()?.snapshot?.takeIf { it.receivedAtMs <= now() } }.getOrNull()
    }

    /** 需要刷新时才解密独立读取配置，UI 无需接触此值。 */
    fun target(): AndroidWidgetTarget? = synchronized(lock) {
        runCatching { load()?.let(::decryptTarget) }.getOrNull()
    }

    /** 缺少能力或元数据不合法时撤销独立获取配置，仍提交合法裁剪摘要。 */
    fun acceptLive(sourceId: String, deviceId: String, snapshot: TerminalSnapshot, message: JSONObject,
                   peerHost: String, receivedAtMs: Long): Boolean = runCatching {
        val value = AndroidWidgetSnapshot.fromLive(sourceId, receivedAtMs, snapshot)
        val endpoint = runCatching {
            require("widgetHttpV1" in AndroidDisplayJson.capabilities(message))
            val data = message.obj("widgetEndpoint")
            AndroidWidgetTarget(sourceId, deviceId, peerHost.lowercase(), data.int("port"), data.string("key"),
                version = data.int("version")).also { it.validate() }
        }.getOrNull()
        acceptLive(value, endpoint)
    }.getOrDefault(false)

    /** 单次原子事务同时切换来源和凭据；相同连接复用 generation，不撤销正常在途请求。 */
    internal fun acceptLive(value: AndroidWidgetSnapshot, nextTarget: AndroidWidgetTarget?): Boolean = synchronized(lock) {
        runCatching {
            value.validate(); require(value.receivedAtMs <= now())
            nextTarget?.validate(); require(nextTarget == null || nextTarget.sourceId == value.sourceId)
            // 坏摘要本身没有可恢复的授权；新的合法认证快照可原子替换并生成全新代次。
            val previous = runCatching { load() }.getOrNull()
            val oldTarget = previous?.let { runCatching { decryptTarget(it) }.getOrNull() }
            val target = nextTarget?.let { candidate ->
                if (oldTarget?.sameConnection(candidate) == true) oldTarget
                else candidate.copy(generation = UUID.randomUUID().toString())
            }
            val snapshot = previous?.snapshot?.takeIf {
                it.sourceId == value.sourceId && it.receivedAtMs > value.receivedAtMs
            } ?: value
            write(AndroidWidgetCodec.State(snapshot, target?.let(::encryptTarget)))
            true
        }.getOrDefault(false)
    }

    /** 忘记精确来源或切换来源时撤销；另一来源的摘要不受影响。 */
    fun clear(sourceId: String? = null): Boolean = synchronized(lock) {
        runCatching {
            require(sourceId == null || MdnsProtocol.isCanonicalDeviceId(sourceId))
            val previous = if (sourceId != null) runCatching { load() }.getOrNull() else null
            if (sourceId != null && previous != null && previous.snapshot.sourceId != sourceId) return@runCatching true
            ensureDirectory()
            Files.deleteIfExists(file.toPath()); Files.deleteIfExists(pending.toPath())
            true
        }.getOrDefault(false)
    }

    /** 比较完整配置和请求起点；迟到响应不能恢复已撤销目标，或覆盖期间到达的新摘要。 */
    fun acceptFetched(target: AndroidWidgetTarget, value: AndroidWidgetSnapshot): Boolean = synchronized(lock) {
        runCatching {
            target.validate(); value.validate(); require(value.receivedAtMs <= now() && target.sourceId == value.sourceId)
            val previous = load() ?: return@runCatching false
            if (decryptTarget(previous) != target || previous.snapshot.sourceId != value.sourceId ||
                previous.snapshot.receivedAtMs > value.receivedAtMs) return@runCatching false
            write(AndroidWidgetCodec.State(value, previous.encryptedTarget))
            true
        }.getOrDefault(false)
    }

    private fun decryptTarget(state: AndroidWidgetCodec.State): AndroidWidgetTarget? {
        val envelope = state.encryptedTarget ?: return null
        require(envelope.size in 29..4096)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, envelope.copyOfRange(0, 12)))
        cipher.updateAAD(aad(state.snapshot.sourceId))
        val bytes = cipher.doFinal(envelope, 12, envelope.size - 12)
        return try { AndroidWidgetCodec.decodeTarget(bytes).also { require(it.sourceId == state.snapshot.sourceId) } }
        finally { bytes.fill(0) }
    }

    private fun encryptTarget(target: AndroidWidgetTarget): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true)); cipher.updateAAD(aad(target.sourceId))
        require(cipher.iv.size == 12)
        val bytes = AndroidWidgetCodec.encodeTarget(target)
        return try { cipher.iv + cipher.doFinal(bytes) } finally { bytes.fill(0) }
    }

    private fun aad(source: String): ByteArray = "LokiMetris/android-widget/1/$source".toByteArray(Charsets.UTF_8)

    private fun load(): AndroidWidgetCodec.State? {
        ensureDirectory()
        if (!Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) return null
        require(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS))
        require(Files.size(file.toPath()) <= AndroidWidgetCodec.MAX_FILE_BYTES)
        return file.inputStream().use { stream ->
            val bytes = AndroidWidgetHttpClient.readBounded(stream, AndroidWidgetCodec.MAX_FILE_BYTES)
            AndroidWidgetCodec.decode(bytes)
        }
    }

    private fun write(state: AndroidWidgetCodec.State) {
        ensureDirectory()
        require(!Files.isSymbolicLink(file.toPath()) && !Files.isSymbolicLink(pending.toPath()))
        val bytes = AndroidWidgetCodec.encode(state)
        try {
            FileOutputStream(pending).use { stream -> stream.write(bytes); stream.fd.sync() }
            Files.move(pending.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            require(Files.size(file.toPath()) == bytes.size.toLong() && file.readBytes().contentEquals(bytes))
        } finally { Files.deleteIfExists(pending.toPath()) }
    }

    private fun ensureDirectory() {
        require(!Files.isSymbolicLink(directory.toPath()))
        require(directory.isDirectory || directory.mkdirs())
    }

    companion object { private val lock = Any() }
}

/** 独立别名避免把组件读取权限与长期配对记录混用；自读不会创建新密钥。 */
private class AndroidWidgetKeystore {
    fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(ALIAS, null)
        if (existing is SecretKey) return existing
        check(create) { "widget_key_unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generateKey()
        }
    }
    companion object { private const val ALIAS = "loki-metris-display-widget-http-v1" }
}
